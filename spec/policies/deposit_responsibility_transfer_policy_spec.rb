require "rails_helper"

RSpec.describe DepositResponsibilityTransferPolicy do
  let(:business) { create(:business) }
  let(:branch)   { create(:branch, business: business) }
  let(:from_user) { create(:user, business: business) }
  let(:to_user)    { create(:user, business: business) }
  let(:third)      { create(:user, business: business) }
  let(:owner)      { create(:user, business: business).tap { |u| business.update!(owner: u) } }

  let(:dr) do
    DailyReconciliation.create!(
      branch: branch, business: business, state: "closed",
      opened_at: 1.hour.ago, closed_at: Time.current, business_date: Date.current
    )
  end

  # A transfer always sits on a closed day whose depositor is from_user.
  let!(:till_session) { TillSession.create!(daily_reconciliation: dr, depositor: from_user) }

  let(:transfer) do
    DepositResponsibilityTransfer.create!(daily_reconciliation: dr, from_user: from_user, to_user: to_user)
  end

  describe "#accept?" do
    it "allows the named recipient" do
      expect(described_class.new(to_user, transfer).accept?).to be true
    end

    it "blocks an unrelated employee" do
      expect(described_class.new(third, transfer).accept?).to be false
    end

    it "blocks the sender" do
      expect(described_class.new(from_user, transfer).accept?).to be false
    end

    it "blocks once accepted" do
      transfer.update!(accepted_at: Time.current)
      expect(described_class.new(to_user, transfer).accept?).to be false
    end

    it "allows the business owner even though the transfer is addressed to someone else" do
      expect(described_class.new(owner, transfer).accept?).to be true
    end

    it "blocks once rejected" do
      transfer.update!(rejected_at: Time.current, rejected_by: to_user)
      expect(described_class.new(to_user, transfer).accept?).to be false
    end

    it "blocks once the day is verified (deposit responsibility can no longer change)" do
      dr.update!(state: "verified", verified_at: Time.current)
      expect(described_class.new(to_user, transfer).accept?).to be false
    end
  end

  describe "#reject?" do
    it "allows only the named recipient while pending" do
      expect(described_class.new(to_user, transfer).reject?).to be true
      expect(described_class.new(from_user, transfer).reject?).to be false
      expect(described_class.new(third, transfer).reject?).to be false
    end

    it "gives the business owner no override" do
      expect(described_class.new(owner, transfer).reject?).to be false
    end

    it "blocks once accepted" do
      transfer.update!(accepted_at: Time.current)
      expect(described_class.new(to_user, transfer).reject?).to be false
    end
  end
end
