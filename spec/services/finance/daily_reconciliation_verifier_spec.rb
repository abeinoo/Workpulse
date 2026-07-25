require "rails_helper"

RSpec.describe Finance::DailyReconciliationVerifier, type: :model do
  let(:business) { create(:business) }
  let(:branch)   { create(:branch, business: business) }
  let(:actor)    { create(:user, business: business) }
  let(:cash_pm)  { PaymentMethod.create!(business: business, name: "Cash", settlement_type: "cash", active: true) }

  # NOT reviewed by default — Branch Review approves the recorded deposit
  # BEFORE bank verification, per the current three-stage order. Tests that
  # need to reach the verify step set reviewed_by/_at explicitly via review!.
  let(:dr) do
    DailyReconciliation.create!(
      branch: branch, business: business, state: "closed",
      opened_at: 1.hour.ago, closed_at: Time.current, business_date: Date.current
    )
  end

  let!(:till_session) { TillSession.create!(daily_reconciliation: dr, depositor_id: actor.id) }
  let!(:session_amount) do
    TillSessionAmount.create!(daily_reconciliation: dr, payment_method: cash_pm, payment_method_name: "Cash",
                              collected_amount: 5_000, refund_amount: 0)
  end

  def verify
    described_class.new(dr.id, actor: actor).call
  end

  def review!
    dr.update_columns(reviewed_by_id: actor.id, reviewed_at: Time.current)
  end

  describe "#call" do
    it "verifies successfully once fully deposited with no other blockers" do
      dr.till_deposits.create!(payment_method: cash_pm, deposited_by: actor, amount: 5_000, deposited_at: Time.current)
      dr.update_columns(state: "deposited")
      review!

      result = verify
      expect(result.ok?).to be true
      expect(dr.reload.verified?).to be true
    end

    it "rejects a recorded deposit that hasn't been reviewed/approved yet" do
      dr.till_deposits.create!(payment_method: cash_pm, deposited_by: actor, amount: 5_000, deposited_at: Time.current)
      dr.update_columns(state: "deposited")

      result = verify
      expect(result.ok?).to be false
      expect(result.error).to eq(I18n.t("finance.daily_reconciliations.errors.verify_requires_deposit_review"))
    end

    it "rejects when already verified" do
      dr.update_columns(state: "verified", verified_at: Time.current, verified_by_id: actor.id)
      result = verify
      expect(result.ok?).to be false
      expect(result.error).to eq(I18n.t("finance.daily_reconciliations.errors.already_verified"))
    end

    it "rejects when still open (never closed)" do
      dr.update_columns(state: "open")
      result = verify
      expect(result.ok?).to be false
      expect(result.error).to eq(I18n.t("finance.daily_reconciliations.errors.not_closed"))
    end

    it "rejects when a till handover is still pending" do
      other = create(:user, business: business)
      TillHandover.create!(daily_reconciliation: dr, from_user: actor, to_user: other,
                            self_deposit: false, fresha_date: dr.business_date)
      result = verify
      expect(result.ok?).to be false
      expect(result.error).to eq(I18n.t("finance.daily_reconciliations.errors.verify_pending_handovers"))
    end

    it "rejects when cash was expected but no deposit exists at all" do
      result = verify
      expect(result.ok?).to be false
      expect(result.error).to eq(I18n.t("finance.daily_reconciliations.errors.verify_no_deposit_recorded"))
    end

    describe "partial deposit is normal — does not block verification" do
      it "allows verification via the real deposit flow even though a partial deposit leaves an open RemainingDepositBalance" do
        Finance::TillDepositRecorder.new(
          dr.id, actor: actor,
          params: { payment_method_id: cash_pm.id, amount: "4000.00", deposited_at: Time.current.to_s }
        ).call
        review!

        result = verify
        expect(result.ok?).to be true
        expect(dr.reload.verified?).to be true
        expect(dr.remaining_deposit_balances.open).not_to be_empty
      end

      it "allows verification when the deposited amount does not cover the full expected amount" do
        dr.till_deposits.create!(payment_method: cash_pm, deposited_by: actor, amount: 4_000, deposited_at: Time.current)
        dr.update_columns(state: "deposited")
        review!
        expect(dr.pending_deposit_amount).to eq(1_000)

        result = verify
        expect(result.ok?).to be true
      end

      it "allows verification once cumulative deposits reach the full expected amount" do
        Finance::TillDepositRecorder.new(
          dr.id, actor: actor,
          params: { payment_method_id: cash_pm.id, amount: "4000.00", deposited_at: Time.current.to_s }
        ).call
        Finance::TillDepositRecorder.new(
          dr.id, actor: actor,
          params: { payment_method_id: cash_pm.id, amount: "1000.00", deposited_at: Time.current.to_s }
        ).call
        review!

        result = verify
        expect(result.ok?).to be true
      end
    end
  end
end
