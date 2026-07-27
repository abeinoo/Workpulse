require "rails_helper"

RSpec.describe Finance::BankDisputes::RemainingBalanceReserver do
  let(:business) { create(:business) }
  let(:branch)   { create(:branch, business: business) }
  let(:employee) { create(:user, business: business) }
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

  describe "when there is no open RemainingDepositBalance" do
    it "is a no-op — most ATM disputes are reported before any deposit exists" do
      expect(RemainingDepositBalance.count).to eq(0)

      dispute = atm_dispute(amount: 200)

      expect(RemainingDepositBalance.count).to eq(0)
      expect(dispute.remaining_deposit_balance_transactions).to be_empty
    end
  end

  describe "with a single open RemainingDepositBalance" do
    it "reduces remaining_amount by the dispute amount and appends a dispute_reserved transaction" do
      deposit!(1_000) # RDB opens for 975
      rdb = RemainingDepositBalance.sole

      dispute = atm_dispute(amount: 200)

      expect(rdb.reload.remaining_amount).to eq(775)
      expect(rdb.status).to eq("open")
      txn = rdb.balance_transactions.dispute_reserved.sole
      expect(txn.amount).to eq(200)
      expect(txn.bank_dispute).to eq(dispute)
    end

    it "moves the balance to status disputed (not settled) when the dispute fully covers it" do
      deposit!(1_000) # RDB opens for 975
      rdb = RemainingDepositBalance.sole

      atm_dispute(amount: 975)

      rdb.reload
      expect(rdb.remaining_amount).to eq(0)
      expect(rdb).to be_disputed
      expect(rdb.closed_at).to be_present
      expect(rdb).to be_closed
    end

    it "caps the reservation at the balance's own remaining_amount, never going negative" do
      deposit!(1_000) # RDB opens for 975
      rdb = RemainingDepositBalance.sole

      atm_dispute(amount: 5_000)

      rdb.reload
      expect(rdb.remaining_amount).to eq(0)
      expect(rdb.balance_transactions.dispute_reserved.sole.amount).to eq(975)
    end

    it "keeps DailyReconciliation#total_remaining_balance and #pending_deposit_amount in agreement" do
      deposit!(1_000)

      atm_dispute(amount: 200)

      expect(dr.reload.total_remaining_balance).to eq(775)
      expect(dr.pending_deposit_amount).to eq(775)
    end

    it "logs an audit entry on the balance" do
      deposit!(1_000)
      rdb = RemainingDepositBalance.sole

      dispute = atm_dispute(amount: 200)

      log = AuditLog.where(auditable: rdb, action: "dispute_reserved").sole
      expect(log.metadata["bank_dispute_id"]).to eq(dispute.id)
      expect(log.metadata["amount"]).to eq("200.0")
    end
  end

  describe "with multiple open RemainingDepositBalances (proportional split)" do
    let(:cash_pm_b) { PaymentMethod.create!(business: business, name: "Cash B", settlement_type: "cash", active: true) }

    it "distributes the dispute proportionally to each balance's own remaining_amount" do
      TillSessionAmount.create!(daily_reconciliation: dr, payment_method: cash_pm_b, payment_method_name: "Cash B",
                                collected_amount: 500, refund_amount: 0)
      deposit!(1_000)                       # RDB A: remaining 975
      Finance::TillDepositRecorder.new(dr.id, actor: employee,
        params: { payment_method_id: cash_pm_b.id, amount: "100.00", deposited_at: Time.current.to_s }).call
      # RDB B: remaining 400

      rdb_a = RemainingDepositBalance.joins(:till_deposit).find_by(till_deposits: { payment_method_id: cash_pm.id })
      rdb_b = RemainingDepositBalance.joins(:till_deposit).find_by(till_deposits: { payment_method_id: cash_pm_b.id })
      total_base = rdb_a.remaining_amount + rdb_b.remaining_amount # 1375

      atm_dispute(amount: 275)

      expected_a = (275 * rdb_a.remaining_amount / total_base).round(2)
      expected_b = (275 * rdb_b.remaining_amount / total_base).round(2)

      expect(rdb_a.reload.remaining_amount.round(2)).to eq((975 - expected_a).round(2))
      expect(rdb_b.reload.remaining_amount.round(2)).to eq((400 - expected_b).round(2))
    end
  end
end
