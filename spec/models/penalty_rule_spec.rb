require "rails_helper"

RSpec.describe PenaltyRule, type: :model do
  subject { build(:penalty_rule) }

  describe "associations" do
    it { is_expected.to belong_to(:shift) }
  end

  describe "validations" do
    it { is_expected.to validate_presence_of(:rule_type) }
    it { is_expected.to validate_presence_of(:deduction_type) }
    it { is_expected.to validate_presence_of(:threshold_minutes) }
    it { is_expected.to validate_presence_of(:deduction_value) }

    it "requires threshold_minutes to be greater than zero" do
      expect(build(:penalty_rule, threshold_minutes: 0)).not_to be_valid
      expect(build(:penalty_rule, threshold_minutes: 1)).to be_valid
    end

    it "requires deduction_value to be greater than zero" do
      expect(build(:penalty_rule, deduction_value: 0)).not_to be_valid
    end

    context "percentage_of_daily deduction_type" do
      it "is valid up to 100%" do
        expect(build(:penalty_rule, :percentage_of_daily, deduction_value: 100)).to be_valid
      end

      it "is invalid above 100%" do
        expect(build(:penalty_rule, :percentage_of_daily, deduction_value: 101)).not_to be_valid
      end
    end

    context "fixed_amount deduction_type" do
      it "allows values above 100" do
        expect(build(:penalty_rule, :fixed_amount, deduction_value: 500)).to be_valid
      end
    end
  end

  describe ".applicable_for" do
    let(:shift) { create(:shift) }
    let!(:rule_15) { create(:penalty_rule, shift: shift, threshold_minutes: 15, deduction_value: 50) }
    let!(:rule_30) { create(:penalty_rule, shift: shift, threshold_minutes: 30, deduction_value: 100) }
    let!(:rule_60) { create(:penalty_rule, shift: shift, threshold_minutes: 60, deduction_value: 200) }

    let(:scope) { shift.penalty_rules.for_late_arrival }

    it "returns the highest matching rule" do
      expect(PenaltyRule.applicable_for(45, scope)).to eq(rule_30)
    end

    it "returns the exact threshold match" do
      expect(PenaltyRule.applicable_for(60, scope)).to eq(rule_60)
    end

    it "returns the lowest applicable rule when minutes barely cross the first threshold" do
      expect(PenaltyRule.applicable_for(15, scope)).to eq(rule_15)
    end

    it "returns nil when minutes are below all thresholds" do
      expect(PenaltyRule.applicable_for(10, scope)).to be_nil
    end
  end
end
