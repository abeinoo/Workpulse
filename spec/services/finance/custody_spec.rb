require "rails_helper"

RSpec.describe "Finance balance account workflows", type: :model do
  let(:business) { create(:business) }
  let(:owner)    { create(:user, :owner, business: business) }
  let(:employee) { create(:user, business: business) }
  let(:account)  { create(:custody_account, business: business, user: owner) }
  let(:account2) { create(:custody_account, business: business, user: employee) }

  def record(acct, params)
    Finance::CustodyTransactionCreator.new(acct, actor: owner, params: params).call
  end

  describe Finance::CustodyTransactionCreator do
    it "stores signed amounts by type and the balance is their sum" do
      record(account, txn_type: "top_up", magnitude: 10_000)
      record(account, txn_type: "adjustment", magnitude: 200, adjustment_direction: "decrease")
      expect(Finance::CustodyBalance.new(account).current).to eq(9_800)
      expect(account.reload.current_balance).to eq(9_800)
    end

    it "rejects a wrong-signed amount via the model guard" do
      expect(account.custody_transactions.new(business: business, txn_type: "top_up", amount: -5)).to be_invalid
    end

    it "records a transfer as a linked, balanced pair" do
      record(account, txn_type: "top_up", magnitude: 5_000)
      result = record(account, txn_type: "transfer", magnitude: 1_000, target_account_id: account2.id)
      expect(result.ok?).to be true
      expect(Finance::CustodyBalance.new(account).current).to eq(4_000)
      expect(Finance::CustodyBalance.new(account2).current).to eq(1_000)
      expect(result.transaction.transfer_counterparty).to be_present
    end

    it "rejects manual expense_deduction — not a MANUAL_TYPE" do
      result = record(account, txn_type: "expense_deduction", magnitude: 500)
      expect(result.ok?).to be false
    end
  end

  describe Finance::TransactionVoider do
    it "voids a transaction (excluding it from the balance) and reverses a transfer's counterpart" do
      record(account, txn_type: "top_up", magnitude: 5_000)
      transfer = record(account, txn_type: "transfer", magnitude: 1_000, target_account_id: account2.id).transaction

      result = described_class.new(transfer, user: owner, reason: "mistake").call
      expect(result.ok?).to be true
      expect(Finance::CustodyBalance.new(account).current).to eq(5_000)
      expect(Finance::CustodyBalance.new(account2).current).to eq(0)
    end
  end
end
