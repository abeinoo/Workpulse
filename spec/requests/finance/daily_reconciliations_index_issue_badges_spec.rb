require "rails_helper"

RSpec.describe "Finance::DailyReconciliations index — issue badges", type: :request do
  let(:business) { create(:business) }
  let(:branch)   { create(:branch, business: business) }

  let!(:cash_pm) { PaymentMethod.create!(business: business, name: "Cash", settlement_type: "cash", active: true) }
  let!(:visa_pm) { PaymentMethod.create!(business: business, name: "Card", settlement_type: "card", active: true, include_in_pos_verification: true) }

  def user_with(*perms)
    role = business.permission_roles.create!(
      name: "R-#{SecureRandom.hex(3)}",
      permissions: perms,
      permission_scopes: perms.index_with { "business_wide" }
    )
    create(:user, business: business).tap { |u| u.update_column(:permission_role_id, role.id) }
  end

  let(:full_viewer) do
    user_with("view_daily_reconciliation", "view_deposit_verification",
              "view_sales_transactions_verification", "view_pos_import",
              "view_all_employee_reconciliation_summary")
  end
  let(:basic_viewer) { user_with("view_daily_reconciliation") }

  let(:dr) do
    DailyReconciliation.create!(
      branch: branch, business: business, state: "closed",
      opened_at: 1.hour.ago, closed_at: Time.current, business_date: Date.current
    )
  end

  let!(:till_session) { TillSession.create!(daily_reconciliation: dr, depositor_id: full_viewer.id) }

  def issue_badges
    I18n.t("finance.daily_reconciliations.index.issue_badges")
  end

  describe "removed duplicate badges" do
    it "no longer shows a Cash Difference badge" do
      TillSessionAmount.create!(daily_reconciliation: dr, payment_method: cash_pm, payment_method_name: "Cash",
                                collected_amount: 500, refund_amount: 0)
      TillDeposit.create!(daily_reconciliation: dr, payment_method: cash_pm, deposited_by: full_viewer,
                          amount: 475, deposited_at: Time.current)

      sign_in full_viewer
      get finance_daily_reconciliations_path

      expect(response.body).not_to include("💵")
    end

    it "no longer shows a plain 'Sales Difference' amount badge — 🧾 now only ever labels Unmatched Sales Transactions" do
      TillSessionAmount.create!(daily_reconciliation: dr, payment_method: cash_pm, payment_method_name: "Cash",
                                collected_amount: 500, refund_amount: 0)
      sales_import = SalesImport.create!(business: business, imported_by: full_viewer, file_name: "export.csv", status: "imported")
      SalesTransaction.create!(
        business: business, sales_import: sales_import, daily_reconciliation: dr,
        transaction_date: dr.business_date, cashier_name: "Ahmed", branch_name: branch.name,
        payment_method_name: "Cash", amount: 406
      )

      sign_in full_viewer
      get finance_daily_reconciliations_path

      # Cash is never pos-verification-flagged, so no Unmatched Sales badge fires either —
      # proving the old unconditional "overall difference" badge is truly gone.
      expect(response.body).not_to include("🧾")
    end
  end

  describe "Outstanding Bank Deposits badge" do
    it "shows the singular form for exactly one unmatched deposit" do
      TillSessionAmount.create!(daily_reconciliation: dr, payment_method: cash_pm, payment_method_name: "Cash",
                                collected_amount: 500, refund_amount: 0)
      TillDeposit.create!(daily_reconciliation: dr, payment_method: cash_pm, deposited_by: full_viewer,
                          amount: 500, deposited_at: Time.current)

      sign_in full_viewer
      get finance_daily_reconciliations_path

      expect(response.body).to include(issue_badges[:outstanding_deposit][:one])
    end

    it "shows the plural form with a count for multiple unmatched deposits" do
      cash_pm_2 = PaymentMethod.create!(business: business, name: "Cash 2", settlement_type: "cash", active: true)
      TillSessionAmount.create!(daily_reconciliation: dr, payment_method: cash_pm, payment_method_name: "Cash",
                                collected_amount: 500, refund_amount: 0)
      TillSessionAmount.create!(daily_reconciliation: dr, payment_method: cash_pm_2, payment_method_name: "Cash 2",
                                collected_amount: 300, refund_amount: 0)
      TillDeposit.create!(daily_reconciliation: dr, payment_method: cash_pm, deposited_by: full_viewer,
                          amount: 500, deposited_at: Time.current)
      TillDeposit.create!(daily_reconciliation: dr, payment_method: cash_pm_2, deposited_by: full_viewer,
                          amount: 300, deposited_at: Time.current)

      sign_in full_viewer
      get finance_daily_reconciliations_path

      expect(response.body).to include(issue_badges[:outstanding_deposit][:other].sub("%{count}", "2"))
    end

    it "does not show once a deposit is matched to a bank statement" do
      TillSessionAmount.create!(daily_reconciliation: dr, payment_method: cash_pm, payment_method_name: "Cash",
                                collected_amount: 500, refund_amount: 0)
      deposit = TillDeposit.create!(daily_reconciliation: dr, payment_method: cash_pm, deposited_by: full_viewer,
                                    amount: 500, deposited_at: Time.current)
      statement = BankStatement.create!(business: business, branch: branch, file_name: "stmt.csv", status: "completed",
                                        statement_from: Date.current, statement_to: Date.current, imported_by: full_viewer)
      txn = BankStatementTransaction.create!(bank_statement: statement, business: business, amount: 500,
                                             transaction_date: Time.current, status: "verified", description: "match")
      DepositMatch.create!(till_deposit: deposit, bank_statement_transaction: txn, matched_amount: 500, matched_at: Time.current)

      sign_in full_viewer
      get finance_daily_reconciliations_path

      expect(response.body).not_to include(issue_badges[:outstanding_deposit][:one])
    end
  end

  describe "Unmatched POS Transactions badge" do
    def create_sales_transaction!(amount:, reference_number:, time: "10:00:00")
      sales_import = SalesImport.create!(business: business, imported_by: full_viewer, file_name: "export.csv", status: "imported")
      SalesTransaction.create!(
        business: business, sales_import: sales_import, daily_reconciliation: dr,
        transaction_date: dr.business_date, transaction_time: time, cashier_name: "Ahmed", branch_name: branch.name,
        payment_method_name: "Card", amount: amount, reference_number: reference_number
      )
    end

    def create_pos_transaction!(amount:, reference_number:)
      pos_import = create(:pos_import, business: business, imported_by: full_viewer)
      create(:pos_transaction, business: business, branch: branch, pos_import: pos_import,
             amount: amount, reference_number: reference_number, payment_method: "Card",
             transaction_date: Time.zone.local(dr.business_date.year, dr.business_date.month, dr.business_date.day, 10))
    end

    it "shows with a count when a POS transaction has no matching Sales transaction" do
      create_pos_transaction!(amount: 75, reference_number: "REF-EXTRA")

      sign_in full_viewer
      get finance_daily_reconciliations_path

      expect(response.body).to include(issue_badges[:pos_unmatched].sub("%{count}", "1"))
    end

    it "does not show when everything matches" do
      create_sales_transaction!(amount: 100, reference_number: "REF-1")
      create_pos_transaction!(amount: 100, reference_number: "REF-1")

      sign_in full_viewer
      get finance_daily_reconciliations_path

      expect(response.body).not_to include("💳")
    end

    it "is hidden for a user without view_pos_import even when unmatched rows exist" do
      create_pos_transaction!(amount: 75, reference_number: "REF-EXTRA")

      sales_only = user_with("view_daily_reconciliation", "view_deposit_verification", "view_sales_transactions_verification")
      sign_in sales_only
      get finance_daily_reconciliations_path

      expect(response.body).not_to include("💳")
    end
  end

  describe "Unmatched Sales Transactions badge" do
    it "shows with a count when a Sales transaction has no matching POS transaction" do
      sales_import = SalesImport.create!(business: business, imported_by: full_viewer, file_name: "export.csv", status: "imported")
      SalesTransaction.create!(
        business: business, sales_import: sales_import, daily_reconciliation: dr,
        transaction_date: dr.business_date, transaction_time: "10:00:00", cashier_name: "Ahmed", branch_name: branch.name,
        payment_method_name: "Card", amount: 200, reference_number: "SALES-ONLY"
      )

      sign_in full_viewer
      get finance_daily_reconciliations_path

      expect(response.body).to include(issue_badges[:sales_unmatched].sub("%{count}", "1"))
    end

    it "does not show when there is no Sales data at all" do
      sign_in full_viewer
      get finance_daily_reconciliations_path

      expect(response.body).not_to include("🧾")
    end
  end

  describe "Employee Sales Reconciliation issue badges" do
    def close_day_for!(cashier, amount)
      close = TillHandover.create!(daily_reconciliation: dr, from_user: cashier, self_deposit: true, accepted_at: Time.current)
      TillHandoverAmount.create!(till_handover: close, payment_method: visa_pm, payment_method_name: "Card",
                                 collected_amount: amount, refund_amount: 0, kind: "operational")
    end

    def create_sales_transaction!(cashier_name:, amount:)
      sales_import = SalesImport.create!(business: business, imported_by: full_viewer, file_name: "export.csv", status: "imported")
      SalesTransaction.create!(
        business: business, sales_import: sales_import, daily_reconciliation: dr,
        transaction_date: dr.business_date, cashier_name: cashier_name, branch_name: branch.name,
        payment_method_name: "Card", amount: amount
      )
    end

    it "shows one badge per employee whose WorkPulse total falls short of their imported Sales total" do
      cashier = create(:user, business: business, first_name: "Mona", last_name: "Fathy")
      close_day_for!(cashier, 500)
      create_sales_transaction!(cashier_name: "Mona Fathy", amount: 555)

      sign_in full_viewer
      get finance_daily_reconciliations_path

      expect(response.body).to include("👤 Mona Fathy")
      expect(response.body).to include(issue_badges[:employee_sales_difference_label])
      expect(response.body).to include("55")
    end

    it "does not show for an employee whose WorkPulse total meets or exceeds their imported Sales total" do
      cashier = create(:user, business: business, first_name: "Sara", last_name: "Adel")
      close_day_for!(cashier, 500)
      create_sales_transaction!(cashier_name: "Sara Adel", amount: 500)

      sign_in full_viewer
      get finance_daily_reconciliations_path

      expect(response.body).not_to include("👤 Sara Adel")
    end

    it "is hidden for a user without view_all_employee_reconciliation_summary" do
      cashier = create(:user, business: business, first_name: "Mona", last_name: "Fathy")
      close_day_for!(cashier, 500)
      create_sales_transaction!(cashier_name: "Mona Fathy", amount: 555)

      no_summary_perm = user_with("view_daily_reconciliation", "view_deposit_verification", "view_sales_transactions_verification")
      sign_in no_summary_perm
      get finance_daily_reconciliations_path

      expect(response.body).not_to include("👤 Mona Fathy")
    end
  end

  it "shows no issue badges at all for a basic viewer without view_deposit_verification" do
    TillSessionAmount.create!(daily_reconciliation: dr, payment_method: cash_pm, payment_method_name: "Cash",
                              collected_amount: 500, refund_amount: 0)

    sign_in basic_viewer
    get finance_daily_reconciliations_path

    expect(response.body).not_to include("💵")
    expect(response.body).not_to include("💳")
    expect(response.body).not_to include("🧾")
    expect(response.body).not_to include("🏦")
    expect(response.body).not_to include("👤")
  end
end
