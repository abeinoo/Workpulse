require "rails_helper"

RSpec.describe BankStatementTransaction, type: :model do
  let(:business) { create(:business) }
  let(:branch)   { create(:branch, business: business) }
  let(:actor)    { create(:user, business: business) }
  let(:payment_method) do
    PaymentMethod.create!(business: business, name: "Cash", settlement_type: "cash", active: true)
  end

  def dr(business_date: Date.current)
    DailyReconciliation.create!(
      branch: branch, business: business, state: "closed",
      opened_at: 1.hour.ago, closed_at: Time.current, business_date: business_date
    )
  end

  def deposit(amount:, date:)
    reconciliation = dr(business_date: date)
    TillSession.create!(daily_reconciliation: reconciliation, depositor_id: actor.id)
    TillDeposit.create!(
      daily_reconciliation: reconciliation, payment_method: payment_method,
      deposited_by: actor, amount: amount, deposited_at: date.to_time + 12.hours
    )
  end

  describe "#date_mismatch_days" do
    it "returns nil when the transaction is not date_mismatch" do
      txn = create(:bank_statement_transaction, :verified, business: business, amount: 300,
                   transaction_date: Date.current)

      expect(txn.date_mismatch_days).to be_nil
    end

    it "returns the day gap to the nearest same-amount unmatched deposit" do
      deposit(amount: 300, date: Date.current + 2.days)
      txn = create(:bank_statement_transaction, :date_mismatch, business: business, amount: 300,
                   transaction_date: Date.current)

      expect(txn.date_mismatch_days).to eq(2)
    end

    it "picks the closest candidate when several same-amount deposits exist on different dates" do
      deposit(amount: 300, date: Date.current + 5.days)
      near = deposit(amount: 300, date: Date.current + 1.day)
      txn = create(:bank_statement_transaction, :date_mismatch, business: business, amount: 300,
                   transaction_date: Date.current)

      expect(txn.date_mismatch_days).to eq(1)
      expect((near.deposited_at.to_date - txn.transaction_date).to_i.abs).to eq(1)
    end

    it "returns nil when no same-amount deposit exists at all" do
      deposit(amount: 999, date: Date.current + 1.day)
      txn = create(:bank_statement_transaction, :date_mismatch, business: business, amount: 300,
                   transaction_date: Date.current)

      expect(txn.date_mismatch_days).to be_nil
    end

    it "ignores deposits already claimed by another match" do
      matched = deposit(amount: 300, date: Date.current + 1.day)
      other_txn = create(:bank_statement_transaction, :verified, business: business, amount: 300,
                         transaction_date: Date.current + 1.day)
      DepositMatch.create_for!(till_deposit: matched, bank_statement_transaction: other_txn)

      txn = create(:bank_statement_transaction, :date_mismatch, business: business, amount: 300,
                   transaction_date: Date.current)

      expect(txn.date_mismatch_days).to be_nil
    end
  end

  describe "#manual_match?" do
    it "is true only when match_method is manual" do
      txn = create(:bank_statement_transaction, :matched, business: business, amount: 300)
      txn.update!(match_method: "manual")

      expect(txn.manual_match?).to be true
    end

    it "is false for an automatically matched transaction" do
      txn = create(:bank_statement_transaction, :matched, business: business, amount: 300)

      expect(txn.manual_match?).to be false
    end
  end
end
