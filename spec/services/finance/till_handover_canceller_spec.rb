require "rails_helper"

RSpec.describe Finance::TillHandoverCanceller, type: :model do
  let(:business) { create(:business) }
  let(:branch)   { create(:branch, business: business) }
  let(:sender)   { create(:user, business: business) }
  let(:receiver) { create(:user, business: business) }
  let(:cash_pm)  { PaymentMethod.create!(business: business, name: "Cash", settlement_type: "cash", active: true) }

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

  def cancel(handover_id: handover.id, actor: sender, reason: nil)
    described_class.new(handover_id, actor: actor, reason: reason).call
  end

  describe "#call" do
    it "cancels the pending handover" do
      result = cancel
      expect(result.ok?).to be true
      expect(handover.reload.cancelled?).to be true
      expect(handover.cancelled_by_id).to eq(sender.id)
    end

    it "leaves custody with the original sender — never touches current_holder" do
      cancel
      expect(till_session.reload.current_holder).to eq(sender)
    end

    it "stores the optional reason and logs it on the audit entry" do
      cancel(reason: "Sent to the wrong person")
      expect(handover.reload.cancellation_reason).to eq("Sent to the wrong person")
      log = AuditLog.where(auditable: handover, action: "cancel").sole
      expect(log.metadata["reason"]).to eq("Sent to the wrong person")
    end

    it "creates no duplicate TillHandover or TillHandoverAmount records" do
      expect { cancel }.not_to change(TillHandover, :count)
    end

    it "rejects cancelling an already-accepted handover" do
      handover.update!(accepted_at: Time.current)
      result = cancel
      expect(result.ok?).to be false
      expect(result.error).to eq(I18n.t("till_handovers.errors.not_cancellable"))
    end

    it "rejects double-cancel (idempotency)" do
      cancel
      result = cancel
      expect(result.ok?).to be false
      expect(result.error).to eq(I18n.t("till_handovers.errors.not_cancellable"))
    end

    it "rejects cancelling an already-rejected handover" do
      handover.update!(rejected_at: Time.current, rejected_by: receiver)
      result = cancel
      expect(result.ok?).to be false
      expect(result.error).to eq(I18n.t("till_handovers.errors.not_cancellable"))
    end

    # Sequential-call simulation of a race: with_lock serializes the two
    # calls on the row lock, so by the time the second call runs it reloads
    # the already-committed terminal state from the first — proving only one
    # terminal transition can ever succeed, without needing real threads
    # (which would fight the spec's transactional wrapper).
    context "race vs accept" do
      it "lets only one of Cancel/Accept win when Cancel goes first" do
        cancel_result = cancel
        accept_result = Finance::TillHandoverAcceptor.new(handover.id, actor: receiver).call

        expect(cancel_result.ok?).to be true
        expect(accept_result.ok?).to be false
        expect(handover.reload.cancelled?).to be true
        expect(handover.accepted?).to be false
        expect(till_session.reload.current_holder).to eq(sender)
      end

      it "lets only one of Cancel/Accept win when Accept goes first" do
        accept_result = Finance::TillHandoverAcceptor.new(handover.id, actor: receiver).call
        cancel_result = cancel

        expect(accept_result.ok?).to be true
        expect(cancel_result.ok?).to be false
        expect(handover.reload.accepted?).to be true
        expect(handover.cancelled?).to be false
        expect(till_session.reload.current_holder).to eq(receiver)
      end
    end
  end
end
