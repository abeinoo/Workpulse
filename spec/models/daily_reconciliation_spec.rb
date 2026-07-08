require "rails_helper"

RSpec.describe DailyReconciliation, type: :model do
  let(:business) { create(:business) }
  let(:branch)   { create(:branch, business: business) }
  let(:actor)    { create(:user, business: business) }

  let(:dr) do
    DailyReconciliation.create!(
      branch: branch, business: business, state: "closed",
      opened_at: 1.hour.ago, closed_at: Time.current, business_date: Date.current
    )
  end

  describe "#reviewed?" do
    it "is false when reviewed_at is nil" do
      expect(dr.reviewed?).to be false
    end

    it "is true when reviewed_at is present" do
      dr.update_columns(reviewed_at: Time.current, reviewed_by_id: actor.id)
      expect(dr.reviewed?).to be true
    end
  end

  describe "#clear_review!" do
    it "clears reviewed_at/reviewed_by and logs an audit event when currently reviewed" do
      dr.update_columns(reviewed_at: 1.minute.ago, reviewed_by_id: actor.id)

      dr.clear_review!(actor: actor)

      expect(dr.reload.reviewed?).to be false
      expect(dr.reviewed_by_id).to be_nil
      log = AuditLog.where(auditable: dr, action: "review_auto_cancelled").sole
      expect(log.actor).to eq(actor)
      expect(log.metadata["reason"]).to eq("Financial data changed after review.")
    end

    it "is a no-op when not currently reviewed" do
      expect { dr.clear_review!(actor: actor) }.not_to change(AuditLog, :count)
    end
  end
end
