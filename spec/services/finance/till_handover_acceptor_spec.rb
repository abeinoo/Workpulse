require "rails_helper"

RSpec.describe Finance::TillHandoverAcceptor, type: :model do
  let(:business) { create(:business) }
  let(:branch)   { create(:branch, business: business) }
  let(:sender)   { create(:user, business: business) }
  let(:receiver) { create(:user, business: business) }
  let(:other)    { create(:user, business: business) }

  let(:dr) do
    DailyReconciliation.create!(
      branch: branch, business: business, state: "open",
      opened_at: 1.hour.ago, business_date: Date.current
    )
  end

  let!(:till_session) { TillSession.create!(daily_reconciliation: dr, current_holder: sender) }

  let!(:handover) do
    TillHandover.create!(daily_reconciliation: dr, from_user: sender, to_user: receiver,
                          self_deposit: false, fresha_date: dr.business_date)
  end

  def accept(handover_id: handover.id, actor: receiver, accepted_notes: nil)
    described_class.new(handover_id, actor: actor, accepted_notes: accepted_notes).call
  end

  describe "#call" do
    it "accepts the pending handover and transfers custody" do
      result = accept
      expect(result.ok?).to be true
      expect(handover.reload.accepted?).to be true
      expect(till_session.reload.current_holder).to eq(receiver)
    end

    it "stores accepted_notes" do
      accept(accepted_notes: "Counted and confirmed")
      expect(handover.reload.accepted_notes).to eq("Counted and confirmed")
    end

    it "writes an audit log" do
      accept
      expect(AuditLog.where(auditable: handover, action: "accept")).to be_present
    end

    it "rejects an unauthorized user (not the intended recipient)" do
      result = accept(actor: other)
      expect(result.ok?).to be false
      expect(result.error).to eq(I18n.t("till_handovers.errors.wrong_recipient"))
      expect(till_session.reload.current_holder).to eq(sender)
    end

    it "rejects double-accept (idempotency / double-submit safety)" do
      accept
      result = accept
      expect(result.ok?).to be false
      expect(result.error).to eq(I18n.t("till_handovers.errors.not_acceptable"))
      expect(till_session.reload.current_holder).to eq(receiver)
    end

    it "rejects accepting an already-cancelled handover" do
      handover.update!(cancelled_at: Time.current, cancelled_by: sender)
      result = accept
      expect(result.ok?).to be false
      expect(result.error).to eq(I18n.t("till_handovers.errors.not_acceptable"))
    end

    it "rejects accepting an already-rejected handover" do
      handover.update!(rejected_at: Time.current, rejected_by: receiver)
      result = accept
      expect(result.ok?).to be false
      expect(result.error).to eq(I18n.t("till_handovers.errors.not_acceptable"))
    end
  end
end
