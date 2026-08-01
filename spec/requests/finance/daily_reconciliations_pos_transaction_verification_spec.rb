require "rails_helper"

RSpec.describe "Finance::DailyReconciliations show — POS Transaction Verification", type: :request do
  let(:business) { create(:business) }
  let(:branch)   { create(:branch, business: business) }

  let!(:visa) { PaymentMethod.create!(business: business, name: "Card", settlement_type: "card", active: true, include_in_pos_verification: true) }
  let!(:cash) { PaymentMethod.create!(business: business, name: "Cash", settlement_type: "cash", active: true, include_in_pos_verification: false) }

  def user_with(*perms)
    role = business.permission_roles.create!(name: "R-#{SecureRandom.hex(3)}", permissions: perms)
    create(:user, business: business).tap { |u| u.update_column(:permission_role_id, role.id) }
  end

  let(:viewer)     { user_with("view_daily_reconciliation", "view_sales_transactions_verification", "view_pos_import") }
  let(:sales_only) { user_with("view_daily_reconciliation", "view_sales_transactions_verification") }
  let(:pos_only)   { user_with("view_daily_reconciliation", "view_pos_import") }
  let(:no_perm)    { user_with("view_daily_reconciliation") }

  let(:dr) do
    DailyReconciliation.create!(
      branch: branch, business: business, state: "closed",
      opened_at: 1.hour.ago, closed_at: Time.current, business_date: Date.current
    )
  end

  let!(:till_session) { TillSession.create!(daily_reconciliation: dr, depositor_id: viewer.id) }

  def create_sales_transaction!(amount: 100, reference_number: "REF-1", payment_method_name: "Card", time: "10:00:00")
    sales_import = SalesImport.create!(business: business, imported_by: viewer, file_name: "export.csv", status: "imported")
    SalesTransaction.create!(
      business: business, sales_import: sales_import, daily_reconciliation: dr,
      transaction_date: dr.business_date, transaction_time: time, cashier_name: "Ahmed", branch_name: branch.name,
      payment_method_name: payment_method_name, amount: amount, reference_number: reference_number
    )
  end

  def create_pos_transaction!(amount: 100, reference_number: "REF-1", payment_method: "Card", hour: 10)
    pos_import = create(:pos_import, business: business, imported_by: viewer)
    create(:pos_transaction, business: business, branch: branch, pos_import: pos_import,
           amount: amount, reference_number: reference_number, payment_method: payment_method,
           transaction_date: Time.zone.local(dr.business_date.year, dr.business_date.month, dr.business_date.day, hour))
  end

  def balanced_text
    I18n.t("finance.daily_reconciliations.show.sections.pos_verification.status_matched")
  end

  describe "section visibility" do
    it "shows the section for a user with both view_sales_transactions_verification and view_pos_import" do
      sign_in viewer
      get finance_daily_reconciliation_path(dr)

      expect(response.body).to include(I18n.t("finance.daily_reconciliations.show.sections.pos_verification.title"))
    end

    it "hides the section for a user with only view_sales_transactions_verification" do
      sign_in sales_only
      get finance_daily_reconciliation_path(dr)

      expect(response.body).not_to include(I18n.t("finance.daily_reconciliations.show.sections.pos_verification.title"))
    end

    it "hides the section for a user with only view_pos_import" do
      sign_in pos_only
      get finance_daily_reconciliation_path(dr)

      expect(response.body).not_to include(I18n.t("finance.daily_reconciliations.show.sections.pos_verification.title"))
    end

    it "hides the section for a user with neither permission" do
      sign_in no_perm
      get finance_daily_reconciliation_path(dr)

      expect(response.body).not_to include(I18n.t("finance.daily_reconciliations.show.sections.pos_verification.title"))
    end
  end

  describe "include_in_pos_verification gating" do
    it "counts a sales transaction whose payment method is flagged include_in_pos_verification" do
      create_sales_transaction!(payment_method_name: "Card", amount: 100)
      create_pos_transaction!(amount: 100)

      sign_in viewer
      get finance_daily_reconciliation_path(dr)

      section = Nokogiri::HTML(response.body).at_css("#pos-transaction-verification")
      expect(section.text).to include(balanced_text)
    end

    it "excludes a sales transaction whose payment method is NOT flagged include_in_pos_verification" do
      create_sales_transaction!(payment_method_name: "Cash", amount: 100)
      create_pos_transaction!(amount: 100)

      sign_in viewer
      get finance_daily_reconciliation_path(dr)

      # The Cash sales transaction never enters the comparison, so the lone
      # POS transaction has nothing to match against — a difference, not a
      # balanced result.
      section = Nokogiri::HTML(response.body).at_css("#pos-transaction-verification")
      expect(section.text).not_to include(balanced_text)
    end
  end

  describe "summary — reuses Bank Deposits' stacked .recon-formula-row layout, not a card grid" do
    it "renders Visa Sales Total / POS Transactions Total / Difference as stacked formula rows, with a status badge — no .stat-card grid at all" do
      create_sales_transaction!
      create_pos_transaction!

      sign_in viewer
      get finance_daily_reconciliation_path(dr)

      doc = Nokogiri::HTML(response.body)
      section = doc.at_css("#pos-transaction-verification")

      expect(section.css(".stats-grid")).to be_empty
      expect(section.css(".stat-card")).to be_empty

      formula_rows = section.css(".recon-formula-row")
      expect(formula_rows.size).to eq(3)
      labels = formula_rows.map { |row| row.at_css("span")&.text }
      expect(labels).to eq([
        I18n.t("finance.daily_reconciliations.show.sections.pos_verification.sales_total"),
        I18n.t("finance.daily_reconciliations.show.sections.pos_verification.pos_total"),
        I18n.t("finance.daily_reconciliations.show.sections.pos_verification.difference")
      ])
      expect(section.css(".recon-formula-row--total").size).to eq(1)

      badge = section.at_css(".badge")
      expect(badge.text.strip).to eq(I18n.t("finance.daily_reconciliations.show.sections.pos_verification.status_matched"))
      expect(badge["class"]).to include("badge-success")
    end

    it "shows a warning badge and the difference amount when totals disagree" do
      create_pos_transaction!(amount: 500)

      sign_in viewer
      get finance_daily_reconciliation_path(dr)

      section = Nokogiri::HTML(response.body).at_css("#pos-transaction-verification")
      badge = section.at_css(".badge")
      expect(badge.text.strip).to eq(I18n.t("finance.daily_reconciliations.show.sections.pos_verification.status_difference"))
      expect(badge["class"]).to include("badge-warning")
      expect(section.css(".recon-formula-row--total").text).to include("500")
    end
  end

  describe "collapsed table" do
    it "keeps the POS Transactions table collapsed by default, behind the shared disclosure component" do
      create_sales_transaction!
      create_pos_transaction!(reference_number: "REF-VISIBLE")

      sign_in viewer
      get finance_daily_reconciliation_path(dr)

      doc = Nokogiri::HTML(response.body)
      # A matched pair produces no unmatched-POS rows, so the only
      # collapsible present is the "POS Transactions" one (block 2).
      disclosure = doc.at_css("#pos-transaction-verification [data-controller='collapsible']")
      expect(disclosure).to be_present

      trigger = disclosure.at_css("[data-collapsible-target='trigger']")
      expect(trigger.text).to include(I18n.t("finance.daily_reconciliations.show.sections.pos_verification.all_pos_title"))
      expect(trigger["aria-expanded"]).to eq("false")

      content = disclosure.at_css("[data-collapsible-target='content']")
      expect(content.has_attribute?("hidden")).to be true

      # The table markup is present (server-rendered) but marked hidden —
      # the disclosure toggles visibility client-side.
      expect(content.text).to include("REF-VISIBLE")
    end

    it "renders each block as its own independent collapsible — no shared accordion group" do
      create_pos_transaction!(reference_number: "REF-ONLY-POS", amount: 75)
      create_sales_transaction!(reference_number: "SALES-ONLY-REF", amount: 999)

      sign_in viewer
      get finance_daily_reconciliation_path(dr)

      doc = Nokogiri::HTML(response.body)
      disclosures = doc.css("#pos-transaction-verification [data-controller='collapsible']")
      # Unmatched POS + All POS + Unmatched Sales — all three rendered here.
      expect(disclosures.size).to eq(3)
      disclosures.each do |d|
        expect(d["data-collapsible-group-value"]).to be_nil
        expect(d.at_css("[data-collapsible-target='content']").has_attribute?("hidden")).to be true
      end
    end

    it "shows every POS transaction — matched, extra, or amount-mismatched alike — in the full table" do
      create_pos_transaction!(reference_number: "REF-MATCHED", amount: 100)
      create_sales_transaction!(reference_number: "REF-MATCHED", amount: 100)
      create_pos_transaction!(reference_number: "REF-EXTRA", amount: 50)

      sign_in viewer
      get finance_daily_reconciliation_path(dr)

      section = Nokogiri::HTML(response.body).at_css("#pos-transaction-verification")
      expect(section.text).to include("REF-MATCHED")
      expect(section.text).to include("REF-EXTRA")
    end

    it "never renders a Sales Transactions table — only the POS side is exposed" do
      create_sales_transaction!
      create_pos_transaction!

      sign_in viewer
      get finance_daily_reconciliation_path(dr)

      section = Nokogiri::HTML(response.body).at_css("#pos-transaction-verification")
      expect(section.css("th").map(&:text)).not_to include("Payment Method")
      expect(section.text).not_to include("Ahmed") # the sales cashier's name — never shown here
    end

    it "does not list a Sales transaction missing from POS inside the POS-only tables — it belongs in its own Unmatched Sales Transactions block" do
      create_sales_transaction!(reference_number: "SALES-ONLY-REF")

      sign_in viewer
      get finance_daily_reconciliation_path(dr)

      section = Nokogiri::HTML(response.body).at_css("#pos-transaction-verification")
      pos_tables = section.css("table").select { |t| t.css("thead th").map(&:text).include?(I18n.t("finance.daily_reconciliations.show.sections.pos_verification.col_terminal_id")) }
      pos_tables.each { |t| expect(t.text).not_to include("SALES-ONLY-REF") }

      # It's shown in the dedicated Unmatched Sales Transactions collapsible instead.
      expect(section.text).to include("SALES-ONLY-REF")
      expect(section.text).to include(I18n.t("finance.daily_reconciliations.show.sections.pos_verification.unmatched_sales_title"))
    end
  end

  describe "Unmatched Sales Transactions table" do
    it "does not render when every Sales Transaction matches (or none exist)" do
      create_sales_transaction!
      create_pos_transaction!

      sign_in viewer
      get finance_daily_reconciliation_path(dr)

      section = Nokogiri::HTML(response.body).at_css("#pos-transaction-verification")
      expect(section.text).not_to include(I18n.t("finance.daily_reconciliations.show.sections.pos_verification.unmatched_sales_title"))
    end

    it "renders, collapsed by default, with only the unmatched Sales Transaction — never a matched or POS-only row" do
      create_sales_transaction!(reference_number: "SALES-UNMATCHED", amount: 321, time: "11:15:00")
      create_sales_transaction!(reference_number: "SALES-MATCHED", amount: 100)
      create_pos_transaction!(reference_number: "SALES-MATCHED", amount: 100)
      create_pos_transaction!(reference_number: "POS-ONLY", amount: 55)

      sign_in viewer
      get finance_daily_reconciliation_path(dr)

      doc = Nokogiri::HTML(response.body)
      section = doc.at_css("#pos-transaction-verification")
      trigger = doc.css("#pos-transaction-verification [data-controller='collapsible']").find do |d|
        d.at_css("[data-collapsible-target='trigger']")&.text&.include?(I18n.t("finance.daily_reconciliations.show.sections.pos_verification.unmatched_sales_title"))
      end
      expect(trigger).to be_present
      expect(trigger.at_css("[data-collapsible-target='trigger']")["aria-expanded"]).to eq("false")
      content = trigger.at_css("[data-collapsible-target='content']")
      expect(content.has_attribute?("hidden")).to be true

      expect(content.text).to include("SALES-UNMATCHED")
      expect(content.text).not_to include("SALES-MATCHED")
      expect(content.text).not_to include("POS-ONLY")
      expect(section.text).to include(I18n.t("finance.daily_reconciliations.show.sections.pos_verification.reason_no_matching_pos"))
    end

    it "includes the required columns: Sale No., Reference No., Transaction Time, Amount, Employee, Reason" do
      create_sales_transaction!(reference_number: "SALES-COLS", amount: 10)

      sign_in viewer
      get finance_daily_reconciliation_path(dr)

      doc = Nokogiri::HTML(response.body)
      trigger = doc.css("#pos-transaction-verification [data-controller='collapsible']").find do |d|
        d.at_css("[data-collapsible-target='trigger']")&.text&.include?(I18n.t("finance.daily_reconciliations.show.sections.pos_verification.unmatched_sales_title"))
      end
      headers = trigger.css("table thead th").map(&:text)
      expect(headers).to eq([
        I18n.t("finance.daily_reconciliations.show.sections.pos_verification.col_sale_number"),
        I18n.t("finance.daily_reconciliations.show.sections.pos_verification.col_reference_number"),
        I18n.t("finance.daily_reconciliations.show.sections.pos_verification.col_time"),
        I18n.t("finance.daily_reconciliations.show.sections.pos_verification.col_amount"),
        I18n.t("finance.daily_reconciliations.show.sections.pos_verification.col_employee"),
        I18n.t("finance.daily_reconciliations.show.sections.pos_verification.col_reason")
      ])
      expect(trigger.text).to include("Ahmed")
    end
  end

  describe "Unmatched POS Transactions table" do
    def tables_in(section)
      section.css("table")
    end

    it "does not render when every POS transaction matches" do
      create_sales_transaction!
      create_pos_transaction!

      sign_in viewer
      get finance_daily_reconciliation_path(dr)

      section = Nokogiri::HTML(response.body).at_css("#pos-transaction-verification")
      expect(section.text).not_to include(I18n.t("finance.daily_reconciliations.show.sections.pos_verification.unmatched_title"))
      expect(tables_in(section).size).to eq(1)
    end

    it "renders FIRST, before the full POS Transactions table, when unmatched rows exist" do
      create_pos_transaction!(reference_number: "REF-ONLY-POS", amount: 75)

      sign_in viewer
      get finance_daily_reconciliation_path(dr)

      section = Nokogiri::HTML(response.body).at_css("#pos-transaction-verification")
      expect(section.text).to include(I18n.t("finance.daily_reconciliations.show.sections.pos_verification.unmatched_title"))
      tables = tables_in(section)
      expect(tables.size).to eq(2)
      # The unmatched table is the first <table> in document order.
      expect(tables.first.text).to include("REF-ONLY-POS")
    end

    it "shows 'No matching sales transaction' with Sales Employee '—' for an extra POS transaction" do
      create_pos_transaction!(reference_number: "REF-EXTRA", amount: 60)

      sign_in viewer
      get finance_daily_reconciliation_path(dr)

      section = Nokogiri::HTML(response.body).at_css("#pos-transaction-verification")
      row = tables_in(section).first.css("tbody tr").first
      cells = row.css("td").map { |td| td.text.strip }
      expect(cells).to include(I18n.t("finance.daily_reconciliations.show.sections.pos_verification.reason_no_matching_sales"))
      expect(cells).to include("—")
    end

    it "shows 'Amount mismatch' with the matched Sales Transaction's cashier as Sales Employee" do
      create_sales_transaction!(reference_number: "REF-MISMATCH", amount: 100)
      create_pos_transaction!(reference_number: "REF-MISMATCH", amount: 90)

      sign_in viewer
      get finance_daily_reconciliation_path(dr)

      section = Nokogiri::HTML(response.body).at_css("#pos-transaction-verification")
      row = tables_in(section).first.css("tbody tr").first
      cells = row.css("td").map { |td| td.text.strip }
      expect(cells).to include(I18n.t("finance.daily_reconciliations.show.sections.pos_verification.reason_amount_mismatch"))
      expect(cells).to include("Ahmed")
    end

    it "includes the required columns: Date, Time, Amount, Reference Number, Terminal ID, Sales Employee, Reason" do
      create_pos_transaction!(reference_number: "REF-COLS", amount: 40)

      sign_in viewer
      get finance_daily_reconciliation_path(dr)

      section = Nokogiri::HTML(response.body).at_css("#pos-transaction-verification")
      headers = tables_in(section).first.css("th").map(&:text)
      expect(headers).to eq([
        I18n.t("finance.daily_reconciliations.show.sections.pos_verification.col_date"),
        I18n.t("finance.daily_reconciliations.show.sections.pos_verification.col_time"),
        I18n.t("finance.daily_reconciliations.show.sections.pos_verification.col_amount"),
        I18n.t("finance.daily_reconciliations.show.sections.pos_verification.col_reference_number"),
        I18n.t("finance.daily_reconciliations.show.sections.pos_verification.col_terminal_id"),
        I18n.t("finance.daily_reconciliations.show.sections.pos_verification.col_sales_employee"),
        I18n.t("finance.daily_reconciliations.show.sections.pos_verification.col_reason")
      ])
    end
  end

  describe "table columns source from transaction_date (Paid At), never created_at" do
    it "shows the Transaction Date and Transaction Time columns, derived from transaction_date" do
      pos_import = create(:pos_import, business: business, imported_by: viewer)
      create(:pos_transaction, business: business, branch: branch, pos_import: pos_import,
             amount: 250, reference_number: "REF-TIME-CHECK", terminal_id: "TERM-9",
             transaction_date: business.timezone_object.local(dr.business_date.year, dr.business_date.month, dr.business_date.day, 14, 37, 0),
             created_at: Time.utc(2020, 1, 1, 0, 0, 0))

      sign_in viewer
      get finance_daily_reconciliation_path(dr)

      expect(response.body).to include(I18n.t("finance.daily_reconciliations.show.sections.pos_verification.col_date"))
      expect(response.body).to include(I18n.t("finance.daily_reconciliations.show.sections.pos_verification.col_time"))
      expect(response.body).to include(dr.business_date.strftime("%Y-%m-%d"))
      expect(response.body).to include("14:37:00")
      expect(response.body).not_to include("2020-01-01")
    end
  end

  describe "calendar-date bucketing — POS Verification totals ignore business_day_start_hour entirely" do
    let(:business) { create(:business, business_day_start_hour: 9) }

    it "matches the imported XLSX total exactly, including an early-morning (pre-rollover) transaction the old for_business_day logic would have excluded" do
      pos_import = create(:pos_import, business: business, imported_by: viewer)
      early = create(:pos_transaction, business: business, branch: branch, pos_import: pos_import,
                     amount: 1000, reference_number: "REF-EARLY", payment_method: "Card",
                     transaction_date: business.timezone_object.local(dr.business_date.year, dr.business_date.month, dr.business_date.day, 0, 30))
      late = create(:pos_transaction, business: business, branch: branch, pos_import: pos_import,
                    amount: 2000, reference_number: "REF-LATE", payment_method: "Card",
                    transaction_date: business.timezone_object.local(dr.business_date.year, dr.business_date.month, dr.business_date.day, 14, 0))
      create_sales_transaction!(amount: 1000, reference_number: "REF-EARLY")
      create_sales_transaction!(amount: 2000, reference_number: "REF-LATE")

      sign_in viewer
      get finance_daily_reconciliation_path(dr)

      # Both the 00:30 (pre-rollover) and 14:00 transactions are found and
      # matched — a business_day_start_hour-aware query would have shifted
      # the 00:30 row to the previous day and excluded it here, leaving a
      # difference instead of a balanced result.
      section = Nokogiri::HTML(response.body).at_css("#pos-transaction-verification")
      expect(section.text).to include("REF-EARLY")
      expect(section.text).to include("REF-LATE")
      expect(section.text).to include(balanced_text)
      [ early, late ].each { |txn| expect(PosTransaction.exists?(txn.id)).to be true }
    end
  end

  describe "branch isolation" do
    it "excludes a POS transaction recorded for a different branch" do
      other_branch = create(:branch, business: business)
      other_pos_import = create(:pos_import, business: business, imported_by: viewer)
      create(:pos_transaction, business: business, branch: other_branch, pos_import: other_pos_import,
             amount: 100, reference_number: "OTHER-BRANCH",
             transaction_date: Time.zone.local(dr.business_date.year, dr.business_date.month, dr.business_date.day, 10))

      sign_in viewer
      get finance_daily_reconciliation_path(dr)

      expect(response.body).not_to include("OTHER-BRANCH")
    end
  end
end
