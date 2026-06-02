require "rails_helper"

# The single approval rule for the entire payroll system.
RSpec.describe Payroll::AdjustmentApproval do
  let(:business) { create(:business) }
  let(:approver) { create(:user, :accountant, business: business) }   # has approve_adjustments
  let(:creator)  { create(:user, :accountant, business: business) }   # has approve_adjustments
  let(:no_perm)  { create(:user, business: business) }                # no permissions

  describe ".permitted?" do
    it "allows a permitted reviewer who is NOT the creator" do
      expect(described_class.permitted?(reviewer: approver, creator: creator)).to be true
    end

    it "blocks the creator even when they hold approve_adjustments" do
      expect(described_class.permitted?(reviewer: creator, creator: creator)).to be false
    end

    it "blocks a reviewer without approve_adjustments" do
      expect(described_class.permitted?(reviewer: no_perm, creator: creator)).to be false
    end

    it "accepts a creator id as well as a User" do
      expect(described_class.permitted?(reviewer: approver, creator: creator.id)).to be true
      expect(described_class.permitted?(reviewer: creator,  creator: creator.id)).to be false
    end

    it "treats a nil creator (system-generated item) as not self-approval" do
      expect(described_class.permitted?(reviewer: approver, creator: nil)).to be true
    end

    it "still requires permission even when creator is nil" do
      expect(described_class.permitted?(reviewer: no_perm, creator: nil)).to be false
    end
  end
end
