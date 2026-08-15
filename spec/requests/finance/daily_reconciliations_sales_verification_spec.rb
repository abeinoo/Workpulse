require "rails_helper"

RSpec.describe "Finance::DailyReconciliations show — POS Transactions Verification", type: :request do
  let(:business) { create(:business) }
  let(:branch)   { create(:branch, business: business) }
  let(:cash_pm)  { PaymentMethod.create!(business: business, name: "Cash", settlement_type: "cash", active: true) }

  def user_with(*perms)
    role = business.permission_roles.create!(name: "R-#{SecureRandom.hex(3)}", permissions: perms)
    create(:user, business: business).tap { |u| u.update_column(:permission_role_id, role.id) }
  end

  let(:viewer)    { user_with("view_daily_reconciliation", "view_sales_transactions_verification") }
  let(:importer)  { user_with("view_daily_reconciliation", "view_sales_transactions_verification", "manage_sales_import") }
  let(:no_perm)   { user_with("view_daily_reconciliation") }

  let(:dr) do
    DailyReconciliation.create!(
      branch: branch, business: business, state: "closed",
      opened_at: 1.hour.ago, closed_at: Time.current, business_date: Date.current
    )
  end

  let!(:till_session)  { TillSession.create!(daily_reconciliation: dr, depositor_id: viewer.id) }
  let!(:session_amount) do
    TillSessionAmount.create!(daily_reconciliation: dr, payment_method: cash_pm, payment_method_name: "Cash",
                              collected_amount: 500, refund_amount: 0)
  end

  def create_sales_transaction!(cashier: "Ahmed", amount: 500, payment_method_name: "Cash")
    sales_import = SalesImport.create!(business: business, imported_by: viewer, file_name: "export.csv", status: "imported")
    SalesTransaction.create!(
      business: business, sales_import: sales_import, daily_reconciliation: dr,
      transaction_date: Date.current, cashier_name: cashier, branch_name: branch.name,
      payment_method_name: payment_method_name, amount: amount
    )
  end

  describe "section visibility" do
    it "shows the POS Transactions Verification section for a user with the permission" do
      sign_in viewer
      get finance_daily_reconciliation_path(dr)

      expect(response.body).to include(I18n.t("finance.sales_imports.verification.title"))
    end

    it "does not show the section for a user without the permission, even with view_daily_reconciliation" do
      sign_in no_perm
      get finance_daily_reconciliation_path(dr)

      expect(response.body).not_to include(I18n.t("finance.sales_imports.verification.title"))
    end

    it "hides POS comparison data even when POS transactions exist for the DR" do
      create_sales_transaction!

      sign_in no_perm
      get finance_daily_reconciliation_path(dr)

      expect(response.body).not_to include(I18n.t("finance.sales_imports.verification.title"))
      expect(response.body).not_to include(I18n.t("finance.sales_imports.verification.branch_totals_title"))
      expect(response.body).not_to include(I18n.t("finance.daily_reconciliations.show.collected_sales_total"))
    end

    it "shows the Session Totals comparison for a permissioned user once POS data exists" do
      card_pm = PaymentMethod.create!(business: business, name: "Visa", settlement_type: "card", active: true)
      TillSessionAmount.create!(daily_reconciliation: dr, payment_method: card_pm, payment_method_name: "Visa",
                                collected_amount: 500, refund_amount: 0)
      create_sales_transaction!(payment_method_name: "Visa")

      sign_in viewer
      get finance_daily_reconciliation_path(dr)

      expect(response.body).to include(I18n.t("finance.daily_reconciliations.show.sections.electronic.session_totals_title"))
      expect(response.body).to include(I18n.t("finance.daily_reconciliations.show.sections.electronic.col_workpulse_total"))
      expect(response.body).to include(I18n.t("finance.daily_reconciliations.show.sections.electronic.col_sales_total"))
      expect(response.body).to include(I18n.t("finance.sales_imports.verification.status_verified"))
      expect(response.body).to include("Visa")
    end

    it "always shows the WorkPulse Session Totals, even before any POS import" do
      card_pm = PaymentMethod.create!(business: business, name: "Visa", settlement_type: "card", active: true)
      TillSessionAmount.create!(daily_reconciliation: dr, payment_method: card_pm, payment_method_name: "Visa",
                                collected_amount: 300, refund_amount: 0)

      sign_in viewer
      get finance_daily_reconciliation_path(dr)

      expect(response.body).to include(I18n.t("finance.daily_reconciliations.show.sections.electronic.session_totals_title"))
      expect(response.body).to include(I18n.t("finance.sales_imports.verification.status_not_imported"))
      expect(response.body).to include("Visa")
    end

    it "shows the Employee Details breakdown with WorkPulse vs Imported POS per employee" do
      cashier_role = business.permission_roles.create!(
        name: "R-#{SecureRandom.hex(3)}",
        permissions: %w[view_daily_reconciliation view_sales_transactions_verification view_all_employee_reconciliation_summary]
      )
      supervisor = create(:user, business: business).tap { |u| u.update_column(:permission_role_id, cashier_role.id) }
      cashier    = create(:user, business: business, first_name: "Mona", last_name: "Fathy")

      card_pm = PaymentMethod.create!(business: business, name: "Visa", settlement_type: "card", active: true)
      TillSessionAmount.create!(daily_reconciliation: dr, payment_method: card_pm, payment_method_name: "Visa",
                                collected_amount: 500, refund_amount: 0)

      # A self-deposit (day-close) handover is the minimal fixture that makes
      # Finance::EmployeeReconciliationSummarizer produce a non-empty summary row.
      close = TillHandover.create!(
        daily_reconciliation: dr, from_user: cashier, self_deposit: true, accepted_at: Time.current
      )
      TillHandoverAmount.create!(till_handover: close, payment_method: card_pm, payment_method_name: "Visa",
                                 collected_amount: 500, refund_amount: 0, kind: "operational")

      create_sales_transaction!(cashier: "Mona Fathy", payment_method_name: "Visa")

      sign_in supervisor
      get finance_daily_reconciliation_path(dr)

      expect(response.body).to include(I18n.t("finance.daily_reconciliations.show.employee_summary_title"))
      expect(response.body).to include(I18n.t("finance.daily_reconciliations.show.sections.electronic.session_totals_title"))
      expect(response.body).to include(I18n.t("finance.daily_reconciliations.show.sections.electronic.col_sales_total"))
      expect(response.body).to include("Mona Fathy")
    end

    it "does not render the removed Electronic Payment Transactions section" do
      sign_in viewer
      get finance_daily_reconciliation_path(dr)

      expect(response.body).not_to include("Electronic Payment Transactions")
    end

    it "shows the import link for a user who additionally has manage_sales_import" do
      sign_in importer
      get finance_daily_reconciliation_path(dr)
      expect(response.body).to include(new_finance_sales_import_path)
    end

    it "hides the import link for a user with only the view permission" do
      sign_in viewer
      get finance_daily_reconciliation_path(dr)
      expect(response.body).not_to include(new_finance_sales_import_path)
    end
  end

  describe "Sales Transactions, grouped by payment method" do
    let(:full_viewer) { user_with("view_daily_reconciliation", "view_sales_transactions_verification", "view_session_totals") }

    def create_sales_transaction_with_time!(cashier:, amount:, payment_method_name:, date:, time:, reference_number: nil)
      sales_import = SalesImport.create!(business: business, imported_by: viewer, file_name: "export.csv", status: "imported")
      SalesTransaction.create!(
        business: business, sales_import: sales_import, daily_reconciliation: dr,
        transaction_date: date, transaction_time: time, cashier_name: cashier, branch_name: branch.name,
        payment_method_name: payment_method_name, amount: amount, reference_number: reference_number
      )
    end

    it "renders one collapsible per payment method, collapsed by default, behind the shared disclosure component" do
      visa_pm = PaymentMethod.create!(business: business, name: "Visa", settlement_type: "card", active: true)
      TillSessionAmount.create!(daily_reconciliation: dr, payment_method: visa_pm, payment_method_name: "Visa",
                                collected_amount: 100, refund_amount: 0)
      create_sales_transaction_with_time!(cashier: "Mona", amount: 100, payment_method_name: "Visa",
                                          date: Date.current, time: "10:00:00", reference_number: "REF-VISA")

      sign_in viewer
      get finance_daily_reconciliation_path(dr)

      doc = Nokogiri::HTML(response.body)
      outer = doc.css("[data-controller='collapsible']").find { |d| d.at_css("[data-collapsible-target='trigger'] span")&.text&.strip == "Visa" }
      expect(outer).to be_present

      trigger = outer.at_css("[data-collapsible-target='trigger']")
      expect(trigger["aria-expanded"]).to eq("false")
      content = outer.at_css("[data-collapsible-target='content']")
      expect(content.has_attribute?("hidden")).to be true
    end

    it "keeps Cash transactions only under Cash, Visa only under Visa, InstaPay only under InstaPay" do
      visa_pm     = PaymentMethod.create!(business: business, name: "Visa", settlement_type: "card", active: true)
      instapay_pm = PaymentMethod.create!(business: business, name: "InstaPay", settlement_type: "ewallet", active: true)
      TillSessionAmount.create!(daily_reconciliation: dr, payment_method: visa_pm, payment_method_name: "Visa",
                                collected_amount: 200, refund_amount: 0)
      TillSessionAmount.create!(daily_reconciliation: dr, payment_method: instapay_pm, payment_method_name: "InstaPay",
                                collected_amount: 300, refund_amount: 0)

      create_sales_transaction_with_time!(cashier: "Ahmed", amount: 100, payment_method_name: "Cash",
                                          date: Date.current, time: "09:00:00", reference_number: "REF-CASH")
      create_sales_transaction_with_time!(cashier: "Mona", amount: 200, payment_method_name: "Visa",
                                          date: Date.current, time: "10:00:00", reference_number: "REF-VISA")
      create_sales_transaction_with_time!(cashier: "Sara", amount: 300, payment_method_name: "InstaPay",
                                          date: Date.current, time: "11:00:00", reference_number: "REF-INSTAPAY")

      sign_in full_viewer
      get finance_daily_reconciliation_path(dr)

      doc = Nokogiri::HTML(response.body)
      block_for = ->(name) { doc.css("[data-controller='collapsible']").find { |d| d.at_css("[data-collapsible-target='trigger'] span")&.text&.strip == name } }

      cash_block     = block_for.call("Cash")
      visa_block     = block_for.call("Visa")
      instapay_block = block_for.call("InstaPay")

      expect(cash_block.text).to include("REF-CASH")
      expect(cash_block.text).not_to include("REF-VISA")
      expect(cash_block.text).not_to include("REF-INSTAPAY")

      expect(visa_block.text).to include("REF-VISA")
      expect(visa_block.text).not_to include("REF-CASH")
      expect(visa_block.text).not_to include("REF-INSTAPAY")

      expect(instapay_block.text).to include("REF-INSTAPAY")
      expect(instapay_block.text).not_to include("REF-CASH")
      expect(instapay_block.text).not_to include("REF-VISA")
    end

    it "shows the WorkPulse/Sales/Difference values directly on the payment-method row, under the shared Session Totals header" do
      visa_pm = PaymentMethod.create!(business: business, name: "Visa", settlement_type: "card", active: true)
      TillSessionAmount.create!(daily_reconciliation: dr, payment_method: visa_pm, payment_method_name: "Visa",
                                collected_amount: 500, refund_amount: 0)
      create_sales_transaction_with_time!(cashier: "Mona", amount: 500, payment_method_name: "Visa",
                                          date: Date.current, time: "10:00:00")

      sign_in viewer
      get finance_daily_reconciliation_path(dr)

      doc = Nokogiri::HTML(response.body)
      visa_block = doc.css("[data-controller='collapsible']").find { |d| d.at_css("[data-collapsible-target='trigger'] span")&.text&.strip == "Visa" }
      trigger = visa_block.at_css("[data-collapsible-target='trigger']")

      %w[col_workpulse_total col_sales_total col_difference].each do |key|
        expect(response.body).to include(I18n.t("finance.daily_reconciliations.show.sections.electronic.#{key}"))
      end
      expect(trigger.text).to include("500")
    end

    it "only Cash/Visa/etc. payment-method rows share the accordion group; the Grand Total row is not collapsible" do
      visa_pm = PaymentMethod.create!(business: business, name: "Visa", settlement_type: "card", active: true)
      TillSessionAmount.create!(daily_reconciliation: dr, payment_method: visa_pm, payment_method_name: "Visa",
                                collected_amount: 500, refund_amount: 0)

      sign_in viewer
      get finance_daily_reconciliation_path(dr)

      doc = Nokogiri::HTML(response.body)
      collapsibles = doc.css("[data-controller='collapsible']")
      expect(collapsibles).not_to be_empty
      collapsibles.each do |c|
        expect(c["data-collapsible-group-value"]).to eq("session-totals-payment-methods")
      end
      expect(response.body).to include(I18n.t("finance.sales_imports.verification.grand_total"))
    end

    it "sorts a payment method's rows by transaction datetime ascending" do
      visa_pm = PaymentMethod.create!(business: business, name: "Visa", settlement_type: "card", active: true)
      TillSessionAmount.create!(daily_reconciliation: dr, payment_method: visa_pm, payment_method_name: "Visa",
                                collected_amount: 300, refund_amount: 0)
      create_sales_transaction_with_time!(cashier: "Ahmed", amount: 100, payment_method_name: "Visa",
                                          date: Date.current, time: "15:00:00", reference_number: "REF-LATE")
      create_sales_transaction_with_time!(cashier: "Mona", amount: 200, payment_method_name: "Visa",
                                          date: Date.current, time: "08:00:00", reference_number: "REF-EARLY")

      sign_in viewer
      get finance_daily_reconciliation_path(dr)

      doc = Nokogiri::HTML(response.body)
      visa_block = doc.css("[data-controller='collapsible']").find { |d| d.at_css("[data-collapsible-target='trigger'] span")&.text&.strip == "Visa" }
      rows = visa_block.css("table tbody tr")
      expect(rows.first.text).to include("REF-EARLY")
      expect(rows.last.text).to include("REF-LATE")
    end

    it "shows Sale Number, Reference Number, Type, Transaction Time, and Amount columns" do
      visa_pm = PaymentMethod.create!(business: business, name: "Visa", settlement_type: "card", active: true)
      TillSessionAmount.create!(daily_reconciliation: dr, payment_method: visa_pm, payment_method_name: "Visa",
                                collected_amount: 100, refund_amount: 0)
      create_sales_transaction_with_time!(cashier: "Ahmed", amount: 100, payment_method_name: "Visa",
                                          date: Date.current, time: "09:00:00", reference_number: "REF-1")

      sign_in viewer
      get finance_daily_reconciliation_path(dr)

      doc = Nokogiri::HTML(response.body)
      visa_block = doc.css("[data-controller='collapsible']").find { |d| d.at_css("[data-collapsible-target='trigger'] span")&.text&.strip == "Visa" }
      headers = visa_block.css("table thead th").map { |th| th.text.strip }

      expect(headers).to eq([
        I18n.t("finance.daily_reconciliations.show.sections.electronic.col_sale_number"),
        I18n.t("finance.daily_reconciliations.show.sections.electronic.col_reference_number"),
        I18n.t("finance.daily_reconciliations.show.sections.electronic.col_type"),
        I18n.t("finance.daily_reconciliations.show.sections.electronic.col_time"),
        I18n.t("finance.daily_reconciliations.show.sections.electronic.col_amount")
      ])
      expect(visa_block.text).to include("REF-1")
    end

    it "shows the Sale Number for a transaction that has one" do
      visa_pm = PaymentMethod.create!(business: business, name: "Visa", settlement_type: "card", active: true)
      TillSessionAmount.create!(daily_reconciliation: dr, payment_method: visa_pm, payment_method_name: "Visa",
                                collected_amount: 100, refund_amount: 0)
      sales_import = SalesImport.create!(business: business, imported_by: viewer, file_name: "export.csv", status: "imported")
      SalesTransaction.create!(
        business: business, sales_import: sales_import, daily_reconciliation: dr,
        transaction_date: Date.current, transaction_time: "09:00:00", cashier_name: "Ahmed", branch_name: branch.name,
        payment_method_name: "Visa", amount: 100, reference_number: "REF-1", sale_number: "SHT-12345"
      )

      sign_in viewer
      get finance_daily_reconciliation_path(dr)

      doc = Nokogiri::HTML(response.body)
      visa_block = doc.css("[data-controller='collapsible']").find { |d| d.at_css("[data-collapsible-target='trigger'] span")&.text&.strip == "Visa" }
      expect(visa_block.text).to include("SHT-12345")
    end

    it "renders no query beyond the already-loaded records (no N+1)" do
      visa_pm = PaymentMethod.create!(business: business, name: "Visa", settlement_type: "card", active: true)
      TillSessionAmount.create!(daily_reconciliation: dr, payment_method: visa_pm, payment_method_name: "Visa",
                                collected_amount: 300, refund_amount: 0)
      3.times { |i| create_sales_transaction_with_time!(cashier: "Ahmed", amount: 100 + i, payment_method_name: "Visa", date: Date.current, time: "09:00:00", reference_number: "REF-#{i}") }

      sign_in viewer
      # SalesTransaction.create! itself issues queries; only assert the GET
      # request doesn't issue one SELECT per row for this table.
      queries = []
      callback = ->(*, payload) { queries << payload[:sql] if payload[:sql].match?(/SELECT.*sales_transactions/i) }
      ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
        get finance_daily_reconciliation_path(dr)
      end

      expect(queries.size).to eq(1)
    end

    it "is not shown for a user without view_sales_transactions_verification" do
      create_sales_transaction!

      sign_in no_perm
      get finance_daily_reconciliation_path(dr)

      expect(response.body).not_to include(I18n.t("finance.daily_reconciliations.show.sections.electronic.session_totals_title"))
      doc = Nokogiri::HTML(response.body)
      expect(doc.css("[data-collapsible-group-value='session-totals-payment-methods']")).to be_empty
    end
  end

  describe "direct endpoint access" do
    it "blocks a user without the permission from the POS import index" do
      sign_in no_perm
      get finance_sales_imports_path
      expect(response).to redirect_to(root_path)
    end

    it "blocks a user without the permission from starting a new POS import" do
      sign_in no_perm
      get new_finance_sales_import_path
      expect(response).to redirect_to(root_path)
    end

    it "allows a user with manage_sales_import to reach the POS import index" do
      sign_in importer
      get finance_sales_imports_path
      expect(response).to have_http_status(:success)
    end
  end

  describe "permission assignment via the role system" do
    it "grants access once the permission is added to the role" do
      role = business.permission_roles.create!(name: "R-#{SecureRandom.hex(3)}", permissions: %w[view_daily_reconciliation])
      user = create(:user, business: business).tap { |u| u.update_column(:permission_role_id, role.id) }

      sign_in user
      get finance_daily_reconciliation_path(dr)
      expect(response.body).not_to include(I18n.t("finance.sales_imports.verification.title"))

      role.update!(permissions: role.permissions + %w[view_sales_transactions_verification])

      get finance_daily_reconciliation_path(dr)
      expect(response.body).to include(I18n.t("finance.sales_imports.verification.title"))
    end

    it "revokes access once the permission is removed from the role" do
      role = business.permission_roles.create!(name: "R-#{SecureRandom.hex(3)}",
                                                 permissions: %w[view_daily_reconciliation view_sales_transactions_verification])
      user = create(:user, business: business).tap { |u| u.update_column(:permission_role_id, role.id) }

      sign_in user
      get finance_daily_reconciliation_path(dr)
      expect(response.body).to include(I18n.t("finance.sales_imports.verification.title"))

      role.update!(permissions: %w[view_daily_reconciliation])

      get finance_daily_reconciliation_path(dr)
      expect(response.body).not_to include(I18n.t("finance.sales_imports.verification.title"))
    end
  end
end
