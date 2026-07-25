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
  end
end
