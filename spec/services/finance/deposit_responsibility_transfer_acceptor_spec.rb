require "rails_helper"

RSpec.describe Finance::DepositResponsibilityTransferAcceptor, type: :model do
  let(:business) { create(:business) }
  let(:branch)   { create(:branch, business: business) }
  let(:from_user) { create(:user, business: business) }
  let(:to_user)    { create(:user, business: business) }

  let(:dr) do
    DailyReconciliation.create!(
      branch: branch, business: business, state: "closed",
      opened_at: 1.hour.ago, closed_at: Time.current, business_date: Date.current
    )
  end

  let!(:till_session) { TillSession.create!(daily_reconciliation: dr, depositor_id: from_user.id) }

  let!(:transfer) do
    DepositResponsibilityTransfer.create!(daily_reconciliation: dr, from_user: from_user, to_user: to_user)
  end

  def accept(actor: to_user)
    described_class.new(transfer.id, actor: actor).call
  end

  describe "#call" do
    it "accepts the transfer and updates the depositor" do
      result = accept
      expect(result.ok?).to be true
      expect(transfer.reload.accepted_at).to be_present
      expect(till_session.reload.depositor).to eq(to_user)
    end

    it "rejects the wrong recipient" do
      other = create(:user, business: business)
      result = accept(actor: other)
      expect(result.ok?).to be false
      expect(result.error).to eq(I18n.t("deposit_responsibility_transfers.errors.wrong_recipient"))
    end

    it "allows the business owner to accept a transfer addressed to someone else" do
      owner = create(:user, :owner, business: business)
      result = accept(actor: owner)
      expect(result.ok?).to be true
      expect(transfer.reload.accepted_at).to be_present
      expect(till_session.reload.depositor).to eq(owner)
    end
  end
end
