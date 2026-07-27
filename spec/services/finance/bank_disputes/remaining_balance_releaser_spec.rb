require "rails_helper"

RSpec.describe Finance::BankDisputes::RemainingBalanceReleaser do
  let(:business) { create(:business) }
  let(:branch)   { create(:branch, business: business) }
  let(:employee) { create(:user, business: business) }
  let(:manager)  { create(:user, business: business) }
  let(:cash_pm)  { PaymentMethod.create!(business: business, name: "Cash", settlement_type: "cash", active: true) }

  let(:dr) do
    DailyReconciliation.create!(
      branch: branch, business: business, state: "closed",
      opened_at: 1.hour.ago, closed_at: Time.current, business_date: Date.current
    )
  end
  let!(:till_session) { TillSession.create!(daily_reconciliation: dr, depositor_id: employee.id) }
  let!(:session_amount) do
    TillSessionAmount.create!(daily_reconciliation: dr, payment_method: cash_pm, payment_method_name: "Cash",
                              collected_amount: 1_975, refund_amount: 0)
  end

  def deposit!(amount)
    Finance::TillDepositRecorder.new(dr.id, actor: employee,
      params: { payment_method_id: cash_pm.id, amount: amount.to_s, deposited_at: Time.current.to_s }).call
  end

  def atm_dispute(amount:)
    Finance::BankDisputes::Creator.new(
      actor: employee, daily_reconciliation_id: dr.id,
      params: { transaction_date: Date.current, transaction_time: "14:00", amount: amount,
                bank_name: "NBE", terminal_id: "ATM-1", card_last4: "1234" }
    ).call.dispute
  end

  def transition!(dispute, to:)
    Finance::BankDisputes::StatusTransitioner.new(dispute.id, actor: manager, target_status: to).call
  end

  describe "when the dispute never reserved anything (no open RDB existed)" do
    it "is a no-op" do
      dispute = atm_dispute(amount: 200)

      transition!(dispute, to: "submitted_to_bank")
      transition!(dispute, to: "under_investigation")
      result = transition!(dispute, to: "rejected")

      expect(result.ok?).to be true
      expect(RemainingDepositBalance.count).to eq(0)
    end
  end

  %w[rejected refunded].each do |status|
    describe "resolving as #{status}" do
      it "restores the exact reserved amount and reopens a fully-disputed balance" do
        deposit!(1_000) # RDB opens for 975
        dispute = atm_dispute(amount: 975) # fully reserves it -> disputed
        rdb = RemainingDepositBalance.sole
        expect(rdb.reload).to be_disputed

        transition!(dispute, to: "submitted_to_bank")
        transition!(dispute, to: "under_investigation")
        transition!(dispute, to: status)

        rdb.reload
        expect(rdb.remaining_amount).to eq(975)
        expect(rdb).to be_open
        expect(rdb.closed_at).to be_nil
      end

      it "restores a partial reservation without over-restoring" do
        deposit!(1_000) # RDB opens for 975
        dispute = atm_dispute(amount: 200)
        rdb = RemainingDepositBalance.sole
        expect(rdb.reload.remaining_amount).to eq(775)

        transition!(dispute, to: "submitted_to_bank")
        transition!(dispute, to: "under_investigation")
        transition!(dispute, to: status)

        expect(rdb.reload.remaining_amount).to eq(975)
      end

      it "appends a dispute_released transaction, never mutating the original dispute_reserved row" do
        deposit!(1_000)
        dispute = atm_dispute(amount: 200)
        rdb = RemainingDepositBalance.sole
        reserved_txn = rdb.balance_transactions.dispute_reserved.sole

        transition!(dispute, to: "submitted_to_bank")
        transition!(dispute, to: "under_investigation")
        transition!(dispute, to: status)

        expect(reserved_txn.reload.amount).to eq(200) # untouched
        released_txn = rdb.balance_transactions.dispute_released.sole
        expect(released_txn.amount).to eq(200)
        expect(released_txn.bank_dispute).to eq(dispute)
      end

      it "keeps DailyReconciliation figures in agreement after restoration" do
        deposit!(1_000)
        dispute = atm_dispute(amount: 200)

        transition!(dispute, to: "submitted_to_bank")
        transition!(dispute, to: "under_investigation")
        transition!(dispute, to: status)

        expect(dr.reload.total_remaining_balance).to eq(975)
        expect(dr.pending_deposit_amount).to eq(975)
      end

      it "does not fire again on the later resolved -> closed transition" do
        deposit!(1_000)
        dispute = atm_dispute(amount: 200)
        rdb = RemainingDepositBalance.sole

        transition!(dispute, to: "submitted_to_bank")
        transition!(dispute, to: "under_investigation")
        transition!(dispute, to: status)
        expect(rdb.reload.remaining_amount).to eq(975)

        transition!(dispute, to: "closed")

        expect(rdb.reload.remaining_amount).to eq(975) # unchanged
        expect(rdb.balance_transactions.dispute_released.count).to eq(1)
      end
    end
  end

  describe "resolving as confirmed_successful" do
    it "transiently restores the balance so the natural deposit-settlement flow can re-close it" do
      deposit!(1_000)
      dispute = atm_dispute(amount: 975)
      rdb = RemainingDepositBalance.sole
      expect(rdb.reload).to be_disputed

      transition!(dispute, to: "submitted_to_bank")
      transition!(dispute, to: "under_investigation")
      transition!(dispute, to: "confirmed_successful")

      rdb.reload
      expect(rdb).to be_open
      expect(rdb.remaining_amount).to eq(975)
      expect(dr.reload.pending_deposit_amount).to eq(975)
    end

    it "is fully re-settled once Finance::BankDisputes::DepositConfirmer converts it to a real deposit" do
      deposit!(1_000)
      dispute = atm_dispute(amount: 975)
      rdb = RemainingDepositBalance.sole

      transition!(dispute, to: "submitted_to_bank")
      transition!(dispute, to: "under_investigation")
      transition!(dispute, to: "confirmed_successful")

      result = Finance::BankDisputes::DepositConfirmer.new(dispute.id, actor: manager, payment_method_id: cash_pm.id).call

      expect(result.ok?).to be true
      rdb.reload
      expect(rdb.remaining_amount).to eq(0)
      expect(rdb).to be_settled # a REAL settlement now, not "disputed"
      expect(dr.reload.total_deposited).to eq(1_975)
      expect(dr.pending_deposit_amount).to eq(0)
      expect(rdb.balance_transactions.ordered.map(&:transaction_type))
        .to eq(%w[created dispute_reserved dispute_released settlement])
    end
  end

  describe "skipping a balance that has since been settled or written off independently" do
    it "does not reopen a balance a manager has already settled by other means" do
      deposit!(1_000)
      dispute = atm_dispute(amount: 200)
      rdb = RemainingDepositBalance.sole
      expect(rdb.reload.remaining_amount).to eq(775)

      Finance::RemainingDepositBalanceSettler.new(rdb.id, actor: manager, amount: 775).call
      expect(rdb.reload).to be_settled

      transition!(dispute, to: "submitted_to_bank")
      transition!(dispute, to: "under_investigation")
      transition!(dispute, to: "rejected")

      expect(rdb.reload).to be_settled
      expect(rdb.remaining_amount).to eq(0)
      expect(rdb.balance_transactions.dispute_released).to be_empty
    end

    it "does not reopen a balance that was written off independently" do
      deposit!(1_000)
      dispute = atm_dispute(amount: 200)
      rdb = RemainingDepositBalance.sole

      Finance::RemainingDepositBalanceWriteOff.new(rdb.id, actor: manager).call
      expect(rdb.reload).to be_written_off

      transition!(dispute, to: "submitted_to_bank")
      transition!(dispute, to: "under_investigation")
      transition!(dispute, to: "rejected")

      expect(rdb.reload).to be_written_off
      expect(rdb.balance_transactions.dispute_released).to be_empty
    end
  end
end
