require "rails_helper"

RSpec.describe Finance::DailyReconciliationReviewCanceller, type: :model do
  let(:business) { create(:business) }
  let(:branch)   { create(:branch, business: business) }
  let(:actor)    { create(:user, business: business) }
  let(:cash_pm)  { PaymentMethod.create!(business: business, name: "Cash", settlement_type: "cash", active: true) }

  # Deposited + reviewed by default — cancelling an approval only makes sense
  # once a deposit exists and has been reviewed.
  let(:dr) do
    DailyReconciliation.create!(
      branch: branch, business: business, state: "deposited",
      opened_at: 1.hour.ago, closed_at: Time.current, business_date: Date.current,
      reviewed_by: actor, reviewed_at: 1.minute.ago
    )
  end
  let!(:till_session) { TillSession.create!(daily_reconciliation: dr, depositor_id: actor.id) }
  let!(:deposit) do
    dr.till_deposits.create!(payment_method: cash_pm, deposited_by: actor, amount: 100, deposited_at: Time.current)
  end

  def cancel(dr_id: dr.id)
    described_class.new(dr_id, actor: actor).call
  end

  describe "#call" do
    it "clears the review" do
      result = cancel
      expect(result.ok?).to be true
      expect(dr.reload.reviewed?).to be false
      expect(dr.reviewed_by_id).to be_nil
      expect(dr.reviewed_at).to be_nil
    end

    it "writes an audit log" do
      cancel
      log = AuditLog.where(auditable: dr, action: "review_cancelled").sole
      expect(log.actor).to eq(actor)
    end

    it "rejects when not currently reviewed" do
      dr.update_columns(reviewed_at: nil, reviewed_by_id: nil)
      result = cancel
      expect(result.ok?).to be false
      expect(result.error).to eq(I18n.t("finance.daily_reconciliations.errors.review_not_reviewed"))
    end

    it "rejects once bank verification is complete" do
      dr.update_columns(state: "verified", verified_at: Time.current, verified_by_id: actor.id)

      result = cancel
      expect(result.ok?).to be false
      expect(result.error).to eq(I18n.t("finance.daily_reconciliations.errors.review_locked_after_verification"))
      expect(dr.reload.reviewed?).to be true
    end
  end

  describe "full rollback of the deposit approval" do
    it "voids the recorded deposit rather than leaving it attached" do
      result = cancel

      expect(result.ok?).to be true
      expect(deposit.reload.voided?).to be true
      expect(deposit.void_reason).to be_present
      expect(deposit.voided_by).to eq(actor)
    end

    it "writes an individual void audit entry for the deposit via TillDepositVoider" do
      cancel
      log = AuditLog.where(auditable: deposit, action: "void").sole
      expect(log.actor).to eq(actor)
    end

    it "records the voided deposit ids on the review_cancelled audit entry" do
      cancel
      log = AuditLog.where(auditable: dr, action: "review_cancelled").sole
      expect(log.metadata["voided_till_deposit_ids"]).to eq([ deposit.id ])
    end

    it "reverts the DR from deposited back to closed — Ready for Deposit" do
      cancel
      expect(dr.reload.state).to eq("closed")
    end

    it "voids every active deposit when more than one payment method was recorded" do
      other_pm = PaymentMethod.create!(business: business, name: "Cash USD", settlement_type: "cash", active: true)
      other_deposit = dr.till_deposits.create!(payment_method: other_pm, deposited_by: actor, amount: 50,
                                               deposited_at: Time.current)

      cancel

      expect(deposit.reload.voided?).to be true
      expect(other_deposit.reload.voided?).to be true
      expect(dr.reload.state).to eq("closed")
    end

    it "leaves an already-voided deposit alone (no double-void), still reverting DR state via the safety net" do
      deposit.update!(voided_at: 1.hour.ago, voided_by: actor, void_reason: "Correction")

      result = cancel

      expect(result.ok?).to be true
      expect(deposit.reload.void_reason).to eq("Correction")
      expect(dr.reload.state).to eq("closed")
    end

    it "allows recording a brand new deposit immediately after cancellation" do
      TillSessionAmount.create!(daily_reconciliation: dr, payment_method: cash_pm, payment_method_name: "Cash",
                                collected_amount: 100, refund_amount: 0)
      cancel

      new_deposit_result = Finance::TillDepositRecorder.new(
        dr.id, actor: actor,
        params: { payment_method_id: cash_pm.id, amount: "100.00", deposited_at: Time.current.to_s }
      ).call

      expect(new_deposit_result.ok?).to be true
      expect(dr.reload.state).to eq("deposited")
      expect(dr.reviewed?).to be false
      expect(dr.till_deposits.active.sole).to eq(new_deposit_result.deposit)
    end

    it "requires the new deposit to be reviewed again before verification" do
      TillSessionAmount.create!(daily_reconciliation: dr, payment_method: cash_pm, payment_method_name: "Cash",
                                collected_amount: 100, refund_amount: 0)
      cancel
      Finance::TillDepositRecorder.new(
        dr.id, actor: actor,
        params: { payment_method_id: cash_pm.id, amount: "100.00", deposited_at: Time.current.to_s }
      ).call

      verify_result = Finance::DailyReconciliationVerifier.new(dr.id, actor: actor).call

      expect(verify_result.ok?).to be false
      expect(verify_result.error).to eq(I18n.t("finance.daily_reconciliations.errors.verify_requires_deposit_review"))
    end
  end
end
