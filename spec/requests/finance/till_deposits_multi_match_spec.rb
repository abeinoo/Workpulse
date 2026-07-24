require "rails_helper"

RSpec.describe "Till deposit multi-transaction bank matching", type: :request do
  let(:business) { create(:business) }
  let(:branch)   { create(:branch, business: business) }

  def user_with(*perms)
    role = business.permission_roles.create!(
      name: "R-#{SecureRandom.hex(3)}",
      permissions: perms,
      permission_scopes: perms.index_with { "business_wide" }
    )
    create(:user, business: business).tap { |u| u.update_column(:permission_role_id, role.id) }
  end

  let(:actor) do
    user_with("view_daily_reconciliation", "close_till_session", "create_till_deposit",
              "view_deposit_verification", "verify_deposits", "manual_match_deposits")
  end

  let(:cash_pm) { PaymentMethod.create!(business: business, name: "Cash", settlement_type: "cash", active: true) }
  let(:statement) { create(:bank_statement, business: business, branch: branch, statement_from: 1.month.ago, statement_to: Date.current) }

  let(:dr) do
    DailyReconciliation.create!(
      branch: branch, business: business, state: "closed",
      opened_at: 1.hour.ago, closed_at: Time.current, business_date: Date.current,
      reviewed_by: actor, reviewed_at: 1.minute.ago
    )
  end
  let!(:till_session) { TillSession.create!(daily_reconciliation: dr, depositor_id: actor.id) }

  def deposit(amount:)
    TillDeposit.create!(daily_reconciliation: dr, payment_method: cash_pm, deposited_by: actor,
                        amount: amount, deposited_at: Time.current)
  end

  def txn(amount:)
    BankStatementTransaction.create!(bank_statement: statement, business: business,
                                     transaction_date: Date.current, amount: amount,
                                     raw_data: {}, status: "unexpected")
  end

  before { sign_in actor }

  describe "GET manual_match_modal" do
    it "shows a checkbox per candidate transaction" do
      dep = deposit(amount: 11_700)
      txn(amount: 7_000)
      txn(amount: 4_700)

      get manual_match_modal_till_deposit_path(dep)

      expect(response.body.scan('type="checkbox"').size).to eq(2)
      expect(response.body).to include("bank_statement_transaction_ids")
    end
  end

  describe "PATCH manual_match with multiple transactions" do
    it "links two transactions summing exactly to the deposit amount — Fully Matched" do
      dep   = deposit(amount: 11_700)
      txn_a = txn(amount: 7_000)
      txn_b = txn(amount: 4_700)

      patch manual_match_till_deposit_path(dep),
            params: { bank_statement_transaction_ids: [ txn_a.id, txn_b.id ] }

      expect(response).to redirect_to(till_deposit_path(dep))
      expect(dep.reload.match_status).to eq(:fully_matched)
      expect(txn_a.reload.status).to eq("verified")
      expect(txn_b.reload.status).to eq("verified")
    end

    it "allows a total less than the deposit amount — Partially Matched" do
      dep   = deposit(amount: 11_700)
      txn_a = txn(amount: 7_000)

      patch manual_match_till_deposit_path(dep), params: { bank_statement_transaction_ids: [ txn_a.id ] }

      expect(dep.reload.match_status).to eq(:partially_matched)
    end

    it "rejects a total greater than the deposit amount and links nothing" do
      dep   = deposit(amount: 11_700)
      txn_a = txn(amount: 7_000)
      txn_b = txn(amount: 6_000)

      patch manual_match_till_deposit_path(dep),
            params: { bank_statement_transaction_ids: [ txn_a.id, txn_b.id ] }

      expect(dep.reload.match_status).to eq(:unmatched)
      expect(txn_a.reload.matched?).to be false
      expect(txn_b.reload.matched?).to be false
    end
  end

  describe "removing one matched transaction" do
    it "keeps the other transaction linked and recalculates to Partially Matched" do
      dep   = deposit(amount: 11_700)
      txn_a = txn(amount: 7_000)
      txn_b = txn(amount: 4_700)
      Finance::BankStatements::ManualMatcher.call_many(
        till_deposit_id: dep.id, transaction_ids: [ txn_a.id, txn_b.id ], actor: actor
      )
      expect(dep.reload.match_status).to eq(:fully_matched)

      patch unmatch_finance_bank_statement_transaction_path(txn_a)

      expect(dep.reload.match_status).to eq(:partially_matched)
      expect(txn_b.reload.matched?).to be true
    end
  end

  describe "reconciliation totals stay correct throughout" do
    it "reflects the matched total on the Daily Reconciliation page" do
      dep   = deposit(amount: 11_700)
      txn_a = txn(amount: 7_000)
      txn_b = txn(amount: 4_700)

      Finance::BankStatements::ManualMatcher.call_many(
        till_deposit_id: dep.id, transaction_ids: [ txn_a.id, txn_b.id ], actor: actor
      )

      get finance_daily_reconciliation_path(dr)

      expect(response).to have_http_status(:ok)
    end
  end
end
