require "rails_helper"

# The Shortage Settlement Deposit custody type (Finance::BulkShortageCustodySettler):
# sign, source, the one-active-credit-per-shortage DB index, and the void lock.
RSpec.describe CustodyTransaction, "shortage_settlement_deposit", type: :model do
  let(:business) { create(:business) }
  let(:branch)   { create(:branch, business: business) }
  let(:actor)    { create(:user, business: business) }
  let(:account)  { create(:custody_account, business: business) }

  let(:dr) do
    DailyReconciliation.create!(branch: branch, business: business, state: "closed",
                                opened_at: 2.hours.ago, closed_at: 1.hour.ago,
                                business_date: Date.new(2026, 11, 1))
  end

  let(:rdb) do
    RemainingDepositBalance.create!(daily_reconciliation: dr, responsible_user: actor, created_by: actor,
                                    business: business, branch: branch, amount: 100,
                                    remaining_amount: 100, status: "open")
  end

  def credit(amount: 100, source: rdb, acct: account)
    acct.custody_transactions.create!(business: acct.business, txn_type: "shortage_settlement_deposit",
                                      amount: amount, source: source, created_by: actor)
  end

  it "must be positive" do
    expect { credit(amount: -100) }.to raise_error(ActiveRecord::RecordInvalid)
  end

  it "must name a RemainingDepositBalance of the same business" do
    expect { credit(source: nil) }.to raise_error(ActiveRecord::RecordInvalid)
    foreign = create(:custody_account)
    expect { credit(acct: foreign) }.to raise_error(ActiveRecord::RecordInvalid)
  end

  describe "idx_custody_txn_one_active_shortage_settlement" do
    it "prevents a second active credit for the same shortage at the database level" do
      credit
      expect { credit }.to raise_error(ActiveRecord::RecordNotUnique)
    end

    it "only counts active rows (a voided row would not block a replacement)" do
      credit.update_column(:voided_at, Time.current)
      expect { credit }.not_to raise_error
    end

    it "does not constrain other custody types sourced elsewhere" do
      credit
      expect {
        account.custody_transactions.create!(business: business, txn_type: "top_up", amount: 100, created_by: actor)
        account.custody_transactions.create!(business: business, txn_type: "top_up", amount: 50, created_by: actor)
      }.not_to raise_error
    end
  end

  describe "voiding" do
    let!(:txn) { credit }

    it "is refused by the model on any path" do
      expect { txn.update!(voided_at: Time.current, voided_by: actor, void_reason: "x") }
        .to raise_error(ActiveRecord::RecordInvalid)
      expect(txn.reload.voided_at).to be_nil
    end

    it "is refused by Finance::TransactionVoider and leaves the balance intact" do
      account.refresh_balance!
      result = Finance::TransactionVoider.new(txn, user: actor, reason: "mistake").call
      expect(result).not_to be_ok
      expect(result.error).to eq(I18n.t("finance.custody.errors.shortage_settlement_linked"))
      expect(account.reload.current_balance).to eq(100)
    end
  end

  describe RemainingDepositBalanceTransaction, "custody link" do
    let!(:txn) { credit }

    def ledger_row(**attrs)
      rdb.balance_transactions.create!({ transaction_type: "settlement", amount: 100, performed_by: actor,
                                         custody_transaction: txn }.merge(attrs))
    end

    it "accepts a settlement mirroring its custody credit" do
      expect(ledger_row).to be_custody_settlement
    end

    it "rejects a mismatched amount, a payment method alongside it, or a non-settlement type" do
      pm = PaymentMethod.create!(business: business, name: "Cash", settlement_type: "cash", active: true)
      expect { ledger_row(amount: 50) }.to raise_error(ActiveRecord::RecordInvalid)
      expect { ledger_row(payment_method: pm) }.to raise_error(ActiveRecord::RecordInvalid)
      expect { ledger_row(transaction_type: "write_off") }.to raise_error(ActiveRecord::RecordInvalid)
    end

    it "rejects a custody credit belonging to another shortage" do
      other = RemainingDepositBalance.create!(daily_reconciliation: dr, responsible_user: actor, created_by: actor,
                                              business: business, branch: branch, amount: 100,
                                              remaining_amount: 100, status: "open")
      expect {
        other.balance_transactions.create!(transaction_type: "settlement", amount: 100, performed_by: actor,
                                           custody_transaction: txn)
      }.to raise_error(ActiveRecord::RecordInvalid)
    end
  end
end
