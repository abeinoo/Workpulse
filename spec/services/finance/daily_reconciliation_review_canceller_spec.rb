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
end
