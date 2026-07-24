require "rails_helper"

RSpec.describe Finance::TillDepositVoider, type: :model do
  let(:business) { create(:business) }
  let(:branch)   { create(:branch, business: business) }
  let(:actor)    { create(:user, business: business) }

  let(:cash_pm) do
    PaymentMethod.create!(
      business:        business,
      name:            "Cash",
      settlement_type: "cash",
      active:          true
    )
  end

  let(:dr) do
    DailyReconciliation.create!(
      branch:        branch,
      business:      business,
      state:         "closed",
      opened_at:     1.hour.ago,
      closed_at:     Time.current,
      business_date: Date.current,
      reviewed_by:   actor,
      reviewed_at:   1.minute.ago
    )
  end

  let!(:till_session)   { TillSession.create!(daily_reconciliation: dr, depositor_id: actor.id) }
  let!(:session_amount) do
    TillSessionAmount.create!(
      daily_reconciliation: dr,
      payment_method:       cash_pm,
      payment_method_name:  cash_pm.name,
      collected_amount:     17_900,
      refund_amount:        0
    )
  end

  def deposit(amount:)
    Finance::TillDepositRecorder.new(
      dr.id, actor: actor,
      params: { payment_method_id: cash_pm.id, amount: amount.to_s, deposited_at: Time.current.to_s }
    ).call.deposit
  end

  def void(deposit, reason: "Wrong amount entered")
    described_class.new(deposit.id, actor: actor, void_reason: reason).call
  end

  describe "#call" do
    it "excludes the voided deposit from total_deposited and pending_deposit_amount" do
      d = deposit(amount: 15_750)
      expect(dr.reload.total_deposited).to eq(15_750)

      result = void(d)
      expect(result.ok?).to be true
      expect(dr.reload.total_deposited).to eq(0)
      expect(dr.pending_deposit_amount).to eq(17_900)
    end

    it "does not touch any existing RemainingDepositBalance — voiding does not try to restore responsibility" do
      d = deposit(amount: 15_750)
      rdb = RemainingDepositBalance.sole
      expect(rdb.remaining_amount).to eq(2_150)

      void(d)

      expect(rdb.reload.remaining_amount).to eq(2_150)
      expect(rdb.status).to eq("open")
      expect(RemainingDepositBalance.count).to eq(1)
    end

    it "does not create a RemainingDepositBalance on void, even when the voided deposit had fully covered the PM" do
      d = deposit(amount: 17_900)
      expect(RemainingDepositBalance.count).to eq(0)

      void(d)

      expect(RemainingDepositBalance.count).to eq(0)
    end

    it "allows immediately re-depositing the full correct amount after voiding the wrong one" do
      wrong = deposit(amount: 15_750)
      void(wrong)

      result = Finance::TillDepositRecorder.new(
        dr.id, actor: actor,
        params: { payment_method_id: cash_pm.id, amount: "17900.00", deposited_at: Time.current.to_s }
      ).call

      expect(result.ok?).to be true
      expect(result.remaining_amount).to be_nil
      expect(dr.reload.total_deposited).to eq(17_900)
      expect(dr.pending_deposit_amount).to eq(0)
      expect(RemainingDepositBalance.sole.reload.status).to eq("settled")
    end

    it "reverts the DR from deposited back to closed when the voided deposit was the only one" do
      d = deposit(amount: 17_900)
      expect(dr.reload.state).to eq("deposited")

      void(d)
      expect(dr.reload.state).to eq("closed")
    end

    it "keeps the DR deposited when another active deposit still exists" do
      other_pm = PaymentMethod.create!(business: business, name: "Cash USD", settlement_type: "cash", active: true)
      TillSessionAmount.create!(daily_reconciliation: dr, payment_method: other_pm,
                                 payment_method_name: other_pm.name, collected_amount: 100, refund_amount: 0)
      Finance::TillDepositRecorder.new(
        dr.id, actor: actor,
        params: { payment_method_id: other_pm.id, amount: "100.00", deposited_at: Time.current.to_s }
      ).call

      d = deposit(amount: 17_900)
      void(d)

      expect(dr.reload.state).to eq("deposited")
    end

    it "writes an audit log entry for the void" do
      d = deposit(amount: 15_750)
      void(d)
      expect(AuditLog.where(auditable: d, action: "void").count).to eq(1)
    end

    it "rejects voiding an already-voided deposit" do
      d = deposit(amount: 15_750)
      void(d)
      result = void(d)

      expect(result.ok?).to be false
      expect(result.error).to eq(I18n.t("till_deposits.errors.already_voided"))
    end

    it "preserves the original deposit, the void, and the replacement as three distinct audit events" do
      original = deposit(amount: 15_750)
      void(original)
      replacement = Finance::TillDepositRecorder.new(
        dr.id, actor: actor,
        params: { payment_method_id: cash_pm.id, amount: "17900.00", deposited_at: Time.current.to_s }
      ).call.deposit

      expect(AuditLog.where(auditable: original, action: "create").count).to eq(1)
      expect(AuditLog.where(auditable: original, action: "void").count).to eq(1)
      expect(AuditLog.where(auditable: replacement, action: "create").count).to eq(1)
      expect(TillDeposit.count).to eq(2)
      expect(original.id).not_to eq(replacement.id)
    end
  end
end
