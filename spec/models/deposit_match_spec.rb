require "rails_helper"

RSpec.describe DepositMatch, type: :model do
  let(:business) { create(:business) }
  let(:branch)   { create(:branch, business: business) }
  let(:actor)    { create(:user, business: business) }
  let(:cash_pm)  { PaymentMethod.create!(business: business, name: "Cash", settlement_type: "cash", active: true) }

  let(:dr) do
    DailyReconciliation.create!(
      branch: branch, business: business, state: "closed",
      opened_at: 1.hour.ago, closed_at: Time.current, business_date: Date.current
      )
  end
  let!(:till_session) { TillSession.create!(daily_reconciliation: dr, depositor_id: actor.id) }

  let(:deposit) do
    TillDeposit.create!(daily_reconciliation: dr, payment_method: cash_pm, deposited_by: actor,
                        amount: 11_700, deposited_at: Time.current)
  end
  let(:statement) { create(:bank_statement, business: business, branch: branch) }

  def txn(amount)
    create(:bank_statement_transaction, business: business, bank_statement: statement, amount: amount)
  end

  describe "validations" do
    it "requires matched_amount to be positive" do
      match = DepositMatch.new(till_deposit: deposit, bank_statement_transaction: txn(100),
                               matched_amount: 0, matched_at: Time.current)
      expect(match).not_to be_valid
      expect(match.errors[:matched_amount]).to be_present
    end

    it "requires matched_at" do
      match = DepositMatch.new(till_deposit: deposit, bank_statement_transaction: txn(100),
                               matched_amount: 100, matched_at: nil)
      expect(match).not_to be_valid
      expect(match.errors[:matched_at]).to be_present
    end

    it "prevents the same bank transaction from being matched twice" do
      transaction = txn(7_000)
      DepositMatch.create!(till_deposit: deposit, bank_statement_transaction: transaction,
                           matched_amount: 7_000, matched_at: Time.current)

      other_deposit = TillDeposit.create!(daily_reconciliation: dr, payment_method: cash_pm,
                                          deposited_by: actor, amount: 7_000, deposited_at: Time.current)
      dup = DepositMatch.new(till_deposit: other_deposit, bank_statement_transaction: transaction,
                             matched_amount: 7_000, matched_at: Time.current)

      expect(dup).not_to be_valid
      expect(dup.errors[:bank_statement_transaction_id]).to be_present
    end
  end

  describe ".create_for!" do
    it "defaults matched_amount to the full bank transaction amount" do
      transaction = txn(4_700)
      match = DepositMatch.create_for!(till_deposit: deposit, bank_statement_transaction: transaction, matched_by: actor)

      expect(match.matched_amount).to eq(4_700)
      expect(match.matched_by).to eq(actor)
      expect(match.matched_at).to be_present
    end

    it "allows a nil matched_by for automatic matches" do
      match = DepositMatch.create_for!(till_deposit: deposit, bank_statement_transaction: txn(100))
      expect(match.matched_by).to be_nil
    end
  end
end
