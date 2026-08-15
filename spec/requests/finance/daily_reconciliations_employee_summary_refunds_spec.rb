require "rails_helper"

# Regression coverage for the bug: an imported POS refund (SalesTransaction
# transaction_type: "refund") was counted as an ADDITIONAL sale (not
# subtracted) in the per-employee "Sales Transactions Verification Summary"
# because @sales_totals_by_cashier summed raw #amount instead of
# #signed_amount. This also left "Cash Reconciliation" showing only a single
# net figure with no Gross/Refund breakdown.
RSpec.describe "Finance::DailyReconciliations show — refunds in Sales Verification Summary and Cash Reconciliation",
               type: :request do
  let(:business) { create(:business) }
  let(:branch)   { create(:branch, business: business) }
  let(:cash_pm)  { PaymentMethod.create!(business: business, name: "Cash", settlement_type: "cash", active: true) }
  let(:visa_pm)  { PaymentMethod.create!(business: business, name: "Visa", settlement_type: "card", active: true) }

  def user_with(*perms)
    role = business.permission_roles.create!(name: "R-#{SecureRandom.hex(3)}", permissions: perms)
    create(:user, business: business).tap { |u| u.update_column(:permission_role_id, role.id) }
  end

  let(:supervisor) do
    user_with("view_daily_reconciliation", "view_sales_transactions_verification",
              "view_all_employee_reconciliation_summary", "view_session_totals")
  end

  let(:dr) do
    DailyReconciliation.create!(
      branch: branch, business: business, state: "closed",
      opened_at: 1.hour.ago, closed_at: Time.current, business_date: Date.current
    )
  end
  let!(:till_session) { TillSession.create!(daily_reconciliation: dr, depositor_id: supervisor.id) }

  def sales_txn!(cashier:, amount:, type: "sale", payment_method_name: "Cash", reference_number: nil)
    sales_import = SalesImport.create!(business: business, imported_by: supervisor, file_name: "export.csv", status: "imported")
    SalesTransaction.create!(
      business: business, sales_import: sales_import, daily_reconciliation: dr,
      transaction_date: Date.current, transaction_time: "10:00:00", cashier_name: cashier, branch_name: branch.name,
      payment_method_name: payment_method_name, amount: amount, transaction_type: type,
      reference_number: reference_number
    )
  end

  # Minimal fixture that makes Finance::EmployeeReconciliationSummarizer
  # produce a non-empty row for `cashier` (mirrors the existing pattern in
  # daily_reconciliations_sales_verification_spec.rb).
  def close_workpulse_custody!(cashier, payment_method:, collected:, refund: 0)
    close = TillHandover.create!(daily_reconciliation: dr, from_user: cashier, self_deposit: true, accepted_at: Time.current)
    TillHandoverAmount.create!(till_handover: close, payment_method: payment_method, payment_method_name: payment_method.display_name,
                               collected_amount: collected, refund_amount: refund, kind: "operational")
  end

  def get_show
    sign_in supervisor
    get finance_daily_reconciliation_path(dr)
    Nokogiri::HTML(response.body)
  end

  # ── Sales Verification Summary: refund appears under the correct employee ──
  describe "Sales Verification Summary" do
    it "nets Gross Sales - Refunds = Net Sales for the employee who made the sale, matching the worked example" do
      cashier = create(:user, business: business, first_name: "Ahmed", last_name: "Bahaa")
      close_workpulse_custody!(cashier, payment_method: cash_pm, collected: 99, refund: 0)
      sales_txn!(cashier: "Ahmed Bahaa", amount: 2099, type: "sale",   payment_method_name: "Cash", reference_number: "S-1")
      sales_txn!(cashier: "Ahmed Bahaa", amount: 2000, type: "refund", payment_method_name: "Cash", reference_number: "R-1")

      doc = get_show
      block = doc.css("[data-controller='collapsible']").find { |d| d.text.include?("Ahmed Bahaa") }
      table_text = block.css("table, div").map(&:text).join(" ")

      expect(table_text).to include("2,099")
      expect(table_text).to include("2,000")
      expect(table_text).to include("99")
    end

    it "attributes a refund to the employee who performed it, even when a different employee made the original sale" do
      seller  = create(:user, business: business, first_name: "Sara",  last_name: "Ali")
      refunder = create(:user, business: business, first_name: "Omar", last_name: "Nabil")
      close_workpulse_custody!(seller, payment_method: cash_pm, collected: 500, refund: 0)
      close_workpulse_custody!(refunder, payment_method: cash_pm, collected: 0, refund: 0)
      sales_txn!(cashier: "Sara Ali",  amount: 500, type: "sale",   payment_method_name: "Cash", reference_number: "S-2")
      sales_txn!(cashier: "Omar Nabil", amount: 200, type: "refund", payment_method_name: "Cash", reference_number: "R-2")

      doc = get_show
      sara_block = doc.css("[data-controller='collapsible']").find { |d| d.text.include?("Sara Ali") }
      omar_block = doc.css("[data-controller='collapsible']").find { |d| d.text.include?("Omar Nabil") }

      expect(sara_block.text).not_to include("R-2")
      expect(omar_block.text).to include("R-2")
      expect(omar_block.text).to match(/200/)
    end

    it "does not inflate the employee's imported total by treating a refund as an extra sale (the core bug)" do
      cashier = create(:user, business: business, first_name: "Mona", last_name: "Fathy")
      close_workpulse_custody!(cashier, payment_method: cash_pm, collected: 300, refund: 0)
      sales_txn!(cashier: "Mona Fathy", amount: 500, type: "sale",   payment_method_name: "Cash", reference_number: "S-3")
      sales_txn!(cashier: "Mona Fathy", amount: 200, type: "refund", payment_method_name: "Cash", reference_number: "R-3")

      sign_in supervisor
      get finance_daily_reconciliation_path(dr)

      # WorkPulse net (300) should equal imported net (500 - 200 = 300) — no
      # spurious Difference warning badge for this employee.
      doc = Nokogiri::HTML(response.body)
      mona_block = doc.css("[data-controller='collapsible']").find { |d| d.text.include?("Mona Fathy") }
      expect(mona_block.css(".badge-warning")).to be_empty
    end

    it "shows Gross Sales, Refunds, and Net Sales as separate figures for a payment method with a refund" do
      cashier = create(:user, business: business, first_name: "Laila", last_name: "Adel")
      close_workpulse_custody!(cashier, payment_method: visa_pm, collected: 300, refund: 0)
      sales_txn!(cashier: "Laila Adel", amount: 500, type: "sale",   payment_method_name: "Visa", reference_number: "S-4")
      sales_txn!(cashier: "Laila Adel", amount: 200, type: "refund", payment_method_name: "Visa", reference_number: "R-4")

      doc = get_show
      block = doc.css("[data-controller='collapsible']").find { |d| d.text.include?("Laila Adel") }

      expect(response.body).to include(I18n.t("finance.daily_reconciliations.show.sections.electronic.col_gross_sales"))
      expect(response.body).to include(I18n.t("finance.daily_reconciliations.show.sections.electronic.col_refunds"))
      expect(block.text).to include("500")
      expect(block.text).to include("200")
      expect(block.text).to include("300")
    end
  end

  # ── Cash Reconciliation: cash refunds reduce expected cash, non-cash refunds don't ──
  describe "Cash Reconciliation" do
    it "shows Gross Cash Sales, Cash Refunds, and a reduced Expected Cash" do
      TillSessionAmount.create!(daily_reconciliation: dr, payment_method: cash_pm, payment_method_name: "Cash",
                                collected_amount: 2099, refund_amount: 2000)

      doc = get_show
      cash_section = doc.at_css("#cash-reconciliation")

      expect(cash_section.text).to include(I18n.t("finance.daily_reconciliations.show.sections.cash.gross_cash_sales"))
      expect(cash_section.text).to include(I18n.t("finance.daily_reconciliations.show.sections.cash.cash_refunds"))
      expect(cash_section.text).to include("2,099")
      expect(cash_section.text).to include("2,000")
      expect(cash_section.text).to include("99")
    end

    it "reduces Expected Cash for a cash refund" do
      TillSessionAmount.create!(daily_reconciliation: dr, payment_method: cash_pm, payment_method_name: "Cash",
                                collected_amount: 500, refund_amount: 200)

      expect(dr.reload.expected_cash_deposit).to eq(300)
    end

    it "does NOT reduce expected cash for a Visa (non-cash) refund" do
      TillSessionAmount.create!(daily_reconciliation: dr, payment_method: cash_pm, payment_method_name: "Cash",
                                collected_amount: 500, refund_amount: 0)
      TillSessionAmount.create!(daily_reconciliation: dr, payment_method: visa_pm, payment_method_name: "Visa",
                                collected_amount: 500, refund_amount: 200)

      expect(dr.reload.expected_cash_deposit).to eq(500)
    end

    it "hides the Cash Refunds row entirely when there are no cash refunds" do
      TillSessionAmount.create!(daily_reconciliation: dr, payment_method: cash_pm, payment_method_name: "Cash",
                                collected_amount: 500, refund_amount: 0)

      doc = get_show
      cash_section = doc.at_css("#cash-reconciliation")
      expect(cash_section.text).not_to include(I18n.t("finance.daily_reconciliations.show.sections.cash.cash_refunds"))
    end
  end

  # ── Employee Reconciliation (WorkPulse custody side) — payment-method scoping is preserved ──
  describe "Employee Reconciliation (WorkPulse custody)" do
    it "nets a cash refund against cash only, never against Visa" do
      cashier = create(:user, business: business)
      close = TillHandover.create!(daily_reconciliation: dr, from_user: cashier, self_deposit: true, accepted_at: Time.current)
      TillHandoverAmount.create!(till_handover: close, payment_method: cash_pm, payment_method_name: "Cash",
                                 collected_amount: 500, refund_amount: 200, kind: "operational")
      TillHandoverAmount.create!(till_handover: close, payment_method: visa_pm, payment_method_name: "Visa",
                                 collected_amount: 500, refund_amount: 0, kind: "operational")

      summaries = Finance::EmployeeReconciliationSummarizer.new(dr).summaries
      row = summaries.find { |s| s.user == cashier }
      cash_row = row.amounts.find { |a| a.payment_method_id == cash_pm.id }
      visa_row = row.amounts.find { |a| a.payment_method_id == visa_pm.id }

      expect(cash_row.net_amount).to eq(300)
      expect(visa_row.net_amount).to eq(500)
    end
  end

  # ── Regression: normal sales-only behavior is unchanged ─────────────────
  describe "regression — no refunds present" do
    it "shows the same Gross/Net figures for a sale-only employee (no Refunds row)" do
      cashier = create(:user, business: business, first_name: "Youssef", last_name: "Kamal")
      close_workpulse_custody!(cashier, payment_method: cash_pm, collected: 500, refund: 0)
      sales_txn!(cashier: "Youssef Kamal", amount: 500, type: "sale", payment_method_name: "Cash", reference_number: "S-5")

      doc = get_show
      block = doc.css("[data-controller='collapsible']").find { |d| d.text.include?("Youssef Kamal") }
      expect(block.text).to include("500")
      expect(block.css(".badge-warning")).to be_empty
    end
  end
end
