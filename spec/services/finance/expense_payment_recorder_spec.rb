require "rails_helper"

RSpec.describe Finance::ExpensePaymentRecorder, type: :model do
  let(:business) { create(:business) }
  let(:branch)   { create(:branch, business: business) }
  let(:category) { create(:expense_category, business: business) }
  let(:payer)    { create(:user, business: business) }
  let(:account)  { create(:custody_account, business: business, user: payer) }

  let(:expense) do
    create(:expense, :approved, business: business, branch: branch, expense_category: category,
           amount: 8_000, deduct_from_balance: false)
  end

  # `actor` is always the person recording THIS payment — "paid from balance"
  # resolves to actor.custody_accounts, never a chosen/other account and
  # never the expense's creator.
  def record(expense, amount:, notes: nil, payment_date: Date.current, paid_from_balance: false, actor: payer)
    described_class.new(expense.id, actor: actor,
      params: { amount: amount, payment_date: payment_date, notes: notes,
                paid_from_balance: paid_from_balance }).call
  end

  it "records a partial payment and derives Total Paid / Remaining from the ledger" do
    result = record(expense, amount: 2_000, notes: "First payment")

    expect(result.ok?).to be true
    expense.reload
    expect(expense.total_settled_amount).to eq(2_000)
    expect(expense.remaining_settlement_amount).to eq(6_000)
    expect(expense.financial_status).to eq("partially_settled")
  end

  it "accumulates multiple installments without overwriting prior ones" do
    record(expense, amount: 2_000)
    record(expense, amount: 3_000)
    record(expense, amount: 3_000)

    expect(expense.financial_settlements.count).to eq(3)
    expect(expense.reload.total_settled_amount).to eq(8_000)
    expect(expense.remaining_settlement_amount).to eq(0)
    expect(expense.financial_status).to eq("settled")
  end

  describe "paid_from_balance: true" do
    it "posts a linked expense_deduction custody transaction and deducts the account balance" do
      Finance::CustodyTransactionCreator.new(account, actor: payer,
        params: { txn_type: "top_up", magnitude: 10_000 }).call

      record(expense, amount: 2_000, paid_from_balance: true)

      txn = account.custody_transactions.find_by(txn_type: "expense_deduction", expense_id: expense.id)
      expect(txn).to be_present
      expect(txn.amount).to eq(-2_000)
      expect(Finance::CustodyBalance.new(account).current).to eq(8_000)
      expect(expense.financial_settlements.sole.funding_source).to eq(account)
    end

    it "allows the funding custody account's own balance to go negative (mirrors ExpenseApproval)" do
      account # force creation
      result = record(expense, amount: 2_000, paid_from_balance: true)
      expect(result.ok?).to be true
      expect(Finance::CustodyBalance.new(account).current).to eq(-2_000)
    end

    it "fails clearly when the actor has no custody account" do
      no_account_user = create(:user, business: business)
      result = record(expense, amount: 100, paid_from_balance: true, actor: no_account_user)
      expect(result.ok?).to be false
      expect(expense.financial_settlements).to be_empty
    end

    it "uses the ACTOR's own account, never a different user's, even if one exists" do
      other_user    = create(:user, business: business)
      other_account = create(:custody_account, business: business, user: other_user)
      Finance::CustodyTransactionCreator.new(account, actor: payer,
        params: { txn_type: "top_up", magnitude: 1_000 }).call

      record(expense, amount: 500, paid_from_balance: true, actor: payer)

      expect(account.custody_transactions.where(expense_id: expense.id)).to be_present
      expect(other_account.custody_transactions.where(expense_id: expense.id)).to be_empty
    end
  end

  describe "paid_from_balance: false (or omitted) — the default" do
    it "records a real payment with no funding source and touches no custody balance" do
      Finance::CustodyTransactionCreator.new(account, actor: payer,
        params: { txn_type: "top_up", magnitude: 10_000 }).call

      result = record(expense, amount: 2_000, paid_from_balance: false)

      expect(result.ok?).to be true
      settlement = expense.reload.financial_settlements.sole
      expect(settlement.funding_source).to be_nil
      expect(expense.total_settled_amount).to eq(2_000) # still counts toward Total Paid
      expect(CustodyTransaction.where(expense_id: expense.id)).to be_empty
      expect(Finance::CustodyBalance.new(account).current).to eq(10_000) # untouched
    end

    it "does not require the actor to have any custody account at all" do
      no_account_user = create(:user, business: business)
      result = record(expense, amount: 100, actor: no_account_user) # paid_from_balance defaults false
      expect(result.ok?).to be true
      expect(expense.reload.total_settled_amount).to eq(100)
    end
  end

  it "mixes custody and non-custody payments on the same expense correctly" do
    Finance::CustodyTransactionCreator.new(account, actor: payer,
      params: { txn_type: "top_up", magnitude: 10_000 }).call

    record(expense, amount: 2_000, paid_from_balance: true)
    record(expense, amount: 3_000, paid_from_balance: false)
    record(expense, amount: 3_000, paid_from_balance: true)

    expense.reload
    expect(expense.total_settled_amount).to eq(8_000)
    expect(expense.remaining_settlement_amount).to eq(0)
    expect(Finance::CustodyBalance.new(account).current).to eq(5_000) # 10,000 - 2,000 - 3,000
    expect(expense.financial_settlements.count).to eq(3)
  end

  it "writes an audit log entry" do
    record(expense, amount: 1_000)
    expect(AuditLog.where(auditable: expense, action: "record_payment").count).to eq(1)
  end

  it "rejects a zero or negative amount" do
    result = record(expense, amount: 0)
    expect(result.ok?).to be false
    expect(expense.financial_settlements).to be_empty
  end

  it "rejects a payment that exceeds the remaining agreed amount" do
    record(expense, amount: 7_000)

    result = record(expense, amount: 1_500)
    expect(result.ok?).to be false
    expect(expense.reload.total_settled_amount).to eq(7_000)
  end

  it "refuses to pay a non-approved expense" do
    pending = create(:expense, :pending, business: business, branch: branch, expense_category: category,
                      amount: 500, deduct_from_balance: false)
    result = record(pending, amount: 100)
    expect(result.ok?).to be false
    expect(pending.financial_settlements).to be_empty
  end
end
