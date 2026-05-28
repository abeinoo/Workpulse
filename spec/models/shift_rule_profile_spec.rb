require "rails_helper"

RSpec.describe ShiftRuleProfile, type: :model do
  let(:business) { create(:business) }

  describe "associations" do
    it { is_expected.to belong_to(:business) }
    it { is_expected.to have_many(:shift_assignments) }
    it { is_expected.to have_many(:shift_template_entries) }
  end

  describe "validations" do
    subject { build(:shift_rule_profile, business: business) }

    it { is_expected.to be_valid }

    it "requires a name" do
      subject.name = nil
      expect(subject).not_to be_valid
    end

    it "requires name to be unique per business" do
      create(:shift_rule_profile, business: business, name: "Ramadan")
      subject.name = "Ramadan"
      expect(subject).not_to be_valid
    end

    it "allows same name for different businesses" do
      other_business = create(:business)
      create(:shift_rule_profile, business: other_business, name: "Ramadan")
      subject.name = "Ramadan"
      expect(subject).to be_valid
    end

    it "validates expected_work_hours > 0 when present" do
      subject.expected_work_hours = 0
      expect(subject).not_to be_valid
    end

    it "allows expected_work_hours nil" do
      subject.expected_work_hours = nil
      expect(subject).to be_valid
    end

    it "validates break_minutes >= 0 when present" do
      subject.break_minutes = -1
      expect(subject).not_to be_valid
    end

    it "validates late_grace_minutes >= 0 when present" do
      subject.late_grace_minutes = -1
      expect(subject).not_to be_valid
    end

    it "validates early_leave_grace_minutes >= 0 when present" do
      subject.early_leave_grace_minutes = -1
      expect(subject).not_to be_valid
    end

    it "validates overtime_multiplier >= 1 when present" do
      subject.overtime_multiplier = 0.5
      expect(subject).not_to be_valid
    end

    it "allows overtime_multiplier nil" do
      subject.overtime_multiplier = nil
      expect(subject).to be_valid
    end
  end

  describe "scopes" do
    it ".active returns only active profiles" do
      active   = create(:shift_rule_profile, business: business, active: true)
      inactive = create(:shift_rule_profile, :inactive, business: business)
      expect(ShiftRuleProfile.active).to include(active)
      expect(ShiftRuleProfile.active).not_to include(inactive)
    end

    it ".for_business scopes by business" do
      other_business = create(:business)
      own   = create(:shift_rule_profile, business: business)
      other = create(:shift_rule_profile, business: other_business)
      expect(ShiftRuleProfile.for_business(business)).to include(own)
      expect(ShiftRuleProfile.for_business(business)).not_to include(other)
    end
  end

  describe "#effective_late_grace" do
    it "returns 0 when late_grace_minutes is nil" do
      subject = build(:shift_rule_profile, late_grace_minutes: nil)
      expect(subject.effective_late_grace).to eq(0)
    end

    it "returns the configured value" do
      subject = build(:shift_rule_profile, late_grace_minutes: 15)
      expect(subject.effective_late_grace).to eq(15)
    end
  end

  describe "#effective_early_leave_grace" do
    it "returns 0 when nil" do
      subject = build(:shift_rule_profile, early_leave_grace_minutes: nil)
      expect(subject.effective_early_leave_grace).to eq(0)
    end

    it "returns the configured value" do
      subject = build(:shift_rule_profile, early_leave_grace_minutes: 10)
      expect(subject.effective_early_leave_grace).to eq(10)
    end
  end

  describe "#overtime_enabled?" do
    it "returns true by default" do
      expect(build(:shift_rule_profile).overtime_enabled?).to be true
    end

    it "returns false when disabled" do
      expect(build(:shift_rule_profile, :overtime_disabled).overtime_enabled?).to be false
    end
  end
end
