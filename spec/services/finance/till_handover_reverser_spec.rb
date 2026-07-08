require "rails_helper"

RSpec.describe Finance::TillHandoverReverser, type: :model do
  let(:business) { create(:business) }
  let(:branch)   { create(:branch, business: business) }
  let(:sender)   { create(:user, business: business) }
  let(:receiver) { create(:user, business: business) }
  let(:third)    { create(:user, business: business) }

  let(:dr) do
    DailyReconciliation.create!(
      branch:        branch,
      business:      business,
      state:         "open",
      opened_at:     1.hour.ago,
      business_date: Date.current
    )
  end

  let!(:till_session) { TillSession.create!(daily_reconciliation: dr, current_holder: receiver) }

  let!(:handover) do
    TillHandover.create!(
      daily_reconciliation: dr,
      from_user:            sender,
      to_user:               receiver,
      self_deposit:          false,
      accepted_at:           1.hour.ago,
      fresha_date:           dr.business_date
    )
  end

  def reverse(actor: receiver, reason_code: "wrong_cash_amount")
    described_class.new(handover_id: handover.id, actor: actor, reason_code: reason_code).call
  end

  describe "#call" do
    it "reverses custody back to the sender while the receiver still holds it" do
      result = reverse
      expect(result.ok?).to be true
      expect(till_session.reload.current_holder).to eq(sender)
      expect(handover.reload.reversed_at).to be_present
    end

    it "still allows reversal while the receiver has a pending, unaccepted outgoing handover" do
      TillHandover.create!(
        daily_reconciliation: dr,
        from_user:            receiver,
        to_user:               third,
        self_deposit:          false,
        fresha_date:           dr.business_date
      )

      result = reverse
      expect(result.ok?).to be true
    end

    it "blocks reversal once a subsequent handover has been accepted" do
      TillHandover.create!(
        daily_reconciliation: dr,
        from_user:            receiver,
        to_user:               third,
        self_deposit:          false,
        accepted_at:           Time.current,
        fresha_date:           dr.business_date
      )
      till_session.update!(current_holder: third)

      result = reverse
      expect(result.ok?).to be false
      expect(result.error).to eq(I18n.t("till_handovers.errors.receiver_started_working"))
      expect(handover.reload.reversed_at).to be_nil
    end

    it "blocks reversal after the receiver has closed the day (self-deposit)" do
      till_session.update!(current_holder: nil)

      result = reverse
      expect(result.ok?).to be false
      expect(result.error).to eq(I18n.t("till_handovers.errors.receiver_started_working"))
    end
  end
end
