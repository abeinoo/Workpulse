require "rails_helper"

RSpec.describe ShiftRuleProfilePolicy, type: :policy do
  let(:business)  { create(:business) }
  let(:owner)     { create(:user, :super_admin, business: business) }
  let(:manager)   { create(:user, business: business) }
  let(:employee)  { create(:user, business: business) }
  let(:profile)   { create(:shift_rule_profile, business: business) }

  describe "index?" do
    it "permits owner" do
      expect(described_class.new(owner, profile).index?).to be true
    end

    it "denies plain employee" do
      expect(described_class.new(employee, profile).index?).to be false
    end
  end

  describe "create? / update?" do
    it "permits owner" do
      expect(described_class.new(owner, profile).create?).to be true
      expect(described_class.new(owner, profile).update?).to be true
    end

    it "denies plain employee" do
      expect(described_class.new(employee, profile).create?).to be false
      expect(described_class.new(employee, profile).update?).to be false
    end
  end

  describe "destroy?" do
    it "permits owner" do
      expect(described_class.new(owner, profile).destroy?).to be true
    end

    it "denies plain employee" do
      expect(described_class.new(employee, profile).destroy?).to be false
    end
  end

  describe "Scope" do
    it "returns profiles for the current user's business only" do
      other_business = create(:business)
      own_profile    = create(:shift_rule_profile, business: business)
      other_profile  = create(:shift_rule_profile, business: other_business)

      scope = described_class::Scope.new(owner, ShiftRuleProfile).resolve
      expect(scope).to include(own_profile)
      expect(scope).not_to include(other_profile)
    end
  end
end
