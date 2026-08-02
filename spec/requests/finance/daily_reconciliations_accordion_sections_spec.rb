require "rails_helper"

RSpec.describe "Finance::DailyReconciliations show — collapsible accordion sections", type: :request do
  let(:business) { create(:business) }
  let(:branch)   { create(:branch, business: business) }
  let!(:cash) { PaymentMethod.create!(business: business, name: "Cash", settlement_type: "cash", active: true) }
  let!(:card) { PaymentMethod.create!(business: business, name: "Card", settlement_type: "card", active: true, include_in_pos_verification: true) }

  def user_with(*perms)
    role = business.permission_roles.create!(name: "R-#{SecureRandom.hex(3)}", permissions: perms)
    create(:user, business: business).tap { |u| u.update_column(:permission_role_id, role.id) }
  end

  let(:viewer) do
    user_with("view_daily_reconciliation", "view_session_totals", "view_sales_transactions_verification",
              "view_pos_import", "view_all_employee_reconciliation_summary")
  end

  let(:dr) do
    DailyReconciliation.create!(
      branch: branch, business: business, state: "closed",
      opened_at: 1.hour.ago, closed_at: Time.current, business_date: Date.current
    )
  end

  let!(:till_session) { TillSession.create!(daily_reconciliation: dr, depositor_id: viewer.id) }

  # key => the section's DOM id (see data-accordion-key-value / section#id in
  # each partial: _electronic_payments, _employee_summary,
  # _cash_reconciliation, _bank_deposits, _pos_transaction_verification).
  ACCORDION_SECTIONS = {
    "sales-verification"         => "electronic-payments",
    "sales-verification-summary" => "sales-verification-summary",
    "cash-reconciliation"        => "cash-reconciliation",
    "bank-deposits"              => "bank-deposits",
    "pos-transactions"           => "pos-transaction-verification"
  }.freeze

  context "with sales, POS, and deposit data present" do
    before do
      sales_import = SalesImport.create!(business: business, imported_by: viewer, file_name: "export.csv", status: "imported")
      SalesTransaction.create!(
        business: business, sales_import: sales_import, daily_reconciliation: dr,
        transaction_date: dr.business_date, transaction_time: "10:00:00", cashier_name: "Ahmed",
        branch_name: branch.name, payment_method_name: "Card", amount: 100, reference_number: "REF-1"
      )
      pos_import = create(:pos_import, business: business, imported_by: viewer)
      create(:pos_transaction, business: business, branch: branch, pos_import: pos_import,
             amount: 100, reference_number: "REF-1", payment_method: "Card",
             transaction_date: Time.zone.local(dr.business_date.year, dr.business_date.month, dr.business_date.day, 10))
      TillDeposit.create!(daily_reconciliation: dr, payment_method: cash, deposited_by: viewer, amount: 50, deposited_at: Time.current)
    end

    it "renders each section as an independent, default-collapsed accordion driven by the accordion controller" do
      sign_in viewer
      get finance_daily_reconciliation_path(dr)
      expect(response).to have_http_status(:ok)

      doc = Nokogiri::HTML(response.body)

      ACCORDION_SECTIONS.each do |key, dom_id|
        section = doc.at_css("##{dom_id}")
        expect(section).to be_present, "expected ##{dom_id} to be present on the page"
        expect(section["data-controller"]).to eq("accordion")
        expect(section["data-accordion-key-value"]).to eq(key)

        trigger = section.at_css("[data-accordion-target='trigger']")
        expect(trigger).to be_present, "expected a trigger inside ##{dom_id}"
        expect(trigger["aria-expanded"]).to eq("false")

        icon = section.at_css("[data-accordion-target='icon']")
        expect(icon.text).to eq("▶")

        content = section.at_css("[data-accordion-target='content']")
        expect(content["class"]).to include("recon-accordion__panel")
        expect(content["class"]).not_to include("recon-accordion__panel--open")
      end
    end

    it "keeps every accordion section independent — no shared data-accordion-group-value" do
      sign_in viewer
      get finance_daily_reconciliation_path(dr)

      doc = Nokogiri::HTML(response.body)
      ACCORDION_SECTIONS.each_value do |dom_id|
        section = doc.at_css("##{dom_id}")
        expect(section["data-accordion-group-value"]).to be_nil
      end
    end

    it "renders summary cards outside of, and unaffected by, any accordion wrapper" do
      sign_in viewer
      get finance_daily_reconciliation_path(dr)

      doc = Nokogiri::HTML(response.body)
      stat_cards = doc.css(".stat-card")
      expect(stat_cards).not_to be_empty
      stat_cards.each do |card|
        expect(card.ancestors.any? { |a| a["data-controller"] == "accordion" }).to be false
      end
    end

    it "leaves the existing nested per-row/per-employee disclosures (collapsible controller) untouched" do
      sign_in viewer
      get finance_daily_reconciliation_path(dr)

      doc = Nokogiri::HTML(response.body)
      expect(doc.css("[data-controller='collapsible']")).not_to be_empty
    end

    it "renders the Audit Log as its own default-collapsed accordion once timeline events exist (a recorded deposit is one)" do
      sign_in viewer
      get finance_daily_reconciliation_path(dr)

      doc = Nokogiri::HTML(response.body)
      section = doc.at_css("#audit-log")
      expect(section).to be_present
      expect(section["data-controller"]).to eq("accordion")
      expect(section["data-accordion-key-value"]).to eq("audit-log")
      expect(section.at_css("[data-accordion-target='icon']").text).to eq("▶")
      expect(section.at_css("[data-accordion-target='content']")["class"]).not_to include("recon-accordion__panel--open")
    end
  end

  it "does not render the Audit Log section at all when there are no timeline events" do
    sign_in viewer
    get finance_daily_reconciliation_path(dr)

    doc = Nokogiri::HTML(response.body)
    expect(doc.at_css("#audit-log")).to be_nil
  end
end
