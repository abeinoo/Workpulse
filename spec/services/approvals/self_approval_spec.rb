require "rails_helper"

RSpec.describe Approvals::SelfApproval do
  let(:business)  { create(:business) }
  let(:requester) { create(:user, business: business) }
  let(:approver)  { create(:user, business: business) }

  describe ".by_requester?" do
    it "is true when the approver is the requester (User)" do
      expect(described_class.by_requester?(approver: requester, requester: requester)).to be(true)
    end

    it "is true when the approver matches the requester id" do
      expect(described_class.by_requester?(approver: requester, requester: requester.id)).to be(true)
    end

    it "is false for a different approver" do
      expect(described_class.by_requester?(approver: approver, requester: requester)).to be(false)
    end

    it "is false when there is no human requester (nil)" do
      expect(described_class.by_requester?(approver: approver, requester: nil)).to be(false)
    end

    it "is false when there is no approver (nil)" do
      expect(described_class.by_requester?(approver: nil, requester: requester)).to be(false)
    end
  end

  describe ".error_message" do
    it "is the clear, user-facing self-approval message" do
      expect(described_class.error_message).to eq("You cannot approve or reject your own request.")
    end
  end
end
