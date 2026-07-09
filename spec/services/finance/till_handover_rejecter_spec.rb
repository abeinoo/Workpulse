require "rails_helper"

RSpec.describe Finance::TillHandoverRejecter, type: :model do
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

  def reject(handover_id: handover.id, actor: receiver, reason: nil)
    described_class.new(handover_id, actor: actor, reason: reason).call
  end

  describe "#call" do
    it "rejects the pending handover" do
      result = reject
      expect(result.ok?).to be true
      expect(handover.reload.rejected?).to be true
      expect(handover.rejected_by_id).to eq(receiver.id)
    end

    it "leaves custody with the original sender — never touches current_holder" do
      reject
      expect(till_session.reload.current_holder).to eq(sender)
    end

    it "stores the optional reason and logs it on the audit entry" do
      reject(reason: "Not my till")
      expect(handover.reload.rejection_reason).to eq("Not my till")
      log = AuditLog.where(auditable: handover, action: "reject").sole
      expect(log.metadata["reason"]).to eq("Not my till")
    end

    it "creates no duplicate TillHandover or TillHandoverAmount records" do
      expect { reject }.not_to change(TillHandover, :count)
    end

    it "rejects an unauthorized user (not the intended recipient)" do
      result = reject(actor: other)
      expect(result.ok?).to be false
      expect(result.error).to eq(I18n.t("till_handovers.errors.wrong_recipient"))
      expect(handover.reload.rejected?).to be false
    end

    it "does not allow the sender to reject their own handover" do
      result = reject(actor: sender)
      expect(result.ok?).to be false
      expect(result.error).to eq(I18n.t("till_handovers.errors.wrong_recipient"))
    end

    it "rejects rejecting an already-accepted handover" do
      handover.update!(accepted_at: Time.current)
      result = reject
      expect(result.ok?).to be false
      expect(result.error).to eq(I18n.t("till_handovers.errors.not_rejectable"))
    end

    it "rejects double-reject (idempotency)" do
      reject
      result = reject
      expect(result.ok?).to be false
      expect(result.error).to eq(I18n.t("till_handovers.errors.not_rejectable"))
    end

    it "rejects rejecting an already-cancelled handover" do
      handover.update!(cancelled_at: Time.current, cancelled_by: sender)
      result = reject
      expect(result.ok?).to be false
      expect(result.error).to eq(I18n.t("till_handovers.errors.not_rejectable"))
    end

    context "race vs accept" do
      it "lets only one of Reject/Accept win when Reject goes first" do
        reject_result = reject
        accept_result = Finance::TillHandoverAcceptor.new(handover.id, actor: receiver).call

        expect(reject_result.ok?).to be true
        expect(accept_result.ok?).to be false
        expect(handover.reload.rejected?).to be true
        expect(handover.accepted?).to be false
        expect(till_session.reload.current_holder).to eq(sender)
      end

      it "lets only one of Reject/Accept win when Accept goes first" do
        accept_result = Finance::TillHandoverAcceptor.new(handover.id, actor: receiver).call
        reject_result = reject

        expect(accept_result.ok?).to be true
        expect(reject_result.ok?).to be false
        expect(handover.reload.accepted?).to be true
        expect(handover.rejected?).to be false
        expect(till_session.reload.current_holder).to eq(receiver)
      end
    end
  end
end
