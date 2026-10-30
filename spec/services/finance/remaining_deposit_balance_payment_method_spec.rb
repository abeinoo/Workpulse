require "rails_helper"

# BUG-032 — a settlement of a remaining deposit balance is an append-only
# ledger row: it may only name an active payment method of the balance's own
# business. Refused settlements write nothing (no row, no partial settlement,
# no audit entry).
RSpec.describe "Remaining deposit balance settlement payment methods (BUG-032)", type: :model do
  let(:business) { create(:business) }
  let(:branch)   { create(:branch, business: business) }
  let(:actor)    { create(:user, business: business) }
  let(:dr) do
    DailyReconciliation.create!(branch: branch, business: business, state: "closed", opened_at: 1.hour.ago,
                                closed_at: Time.current, business_date: Date.current)
  end
  let(:balance) do
    RemainingDepositBalance.create!(daily_reconciliation: dr, responsible_user: actor, created_by: actor,
                                    business: business, branch: branch, amount: 200, remaining_amount: 200,
                                    status: "open")
  end
  let(:cash)     { PaymentMethod.create!(business: business, name: "Cash", settlement_type: "cash", active: true) }
  let(:retired)  { PaymentMethod.create!(business: business, name: "Old", settlement_type: "cash", active: false) }
  let(:foreign)  { PaymentMethod.create!(business: create(:business), name: "Wallet", settlement_type: "cash", active: true) }

  def settle(payment_method_id:, amount: 50)
    Finance::RemainingDepositBalanceSettler.new(balance.id, actor: actor, amount: amount,
                                                payment_method_id: payment_method_id).call
  end

  def nothing_written
    change { [ RemainingDepositBalanceTransaction.count, balance.reload.remaining_amount, AuditLog.count ] }
  end

  describe Finance::RemainingDepositBalanceSettler do
    before { balance }

    {
      "another business's payment method" => -> { foreign.id },
      "an inactive payment method"         => -> { retired.id },
      "a payment method that does not exist" => -> { PaymentMethod.maximum(:id).to_i + 1000 }
    }.each do |label, id|
      it "refuses #{label}, writing nothing" do
        pm_id = instance_exec(&id)

        expect { @result = settle(payment_method_id: pm_id) }.not_to nothing_written
        expect(@result).not_to be_ok
        expect(@result.error).to eq(I18n.t("remaining_deposit_balances.errors.invalid_payment_method"))
        expect(balance.reload).to be_open
      end
    end

    it "settles with an active payment method of the business" do
      result = settle(payment_method_id: cash.id)

      expect(result).to be_ok
      expect(result.transaction.payment_method_id).to eq(cash.id)
      expect(balance.reload.remaining_amount).to eq(150)
    end

    it "still settles without a payment method" do
      result = settle(payment_method_id: "")

      expect(result).to be_ok
      expect(result.transaction.payment_method_id).to be_nil
    end
  end

  describe RemainingDepositBalanceTransaction do
    it "refuses a ledger row naming another business's payment method on a direct write" do
      txn = balance.balance_transactions.build(transaction_type: "settlement", amount: 10, performed_by: actor,
                                               payment_method: foreign)

      expect(txn.save).to be(false)
      expect(txn.errors.where(:payment_method_id, :other_business)).to be_present
    end

    it "accepts the business's own payment method" do
      txn = balance.balance_transactions.build(transaction_type: "settlement", amount: 10, performed_by: actor,
                                               payment_method: cash)

      expect(txn.save).to be(true)
    end
  end
end
