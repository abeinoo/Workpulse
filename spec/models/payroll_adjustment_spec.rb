require "rails_helper"

RSpec.describe PayrollAdjustment, type: :model do
  subject(:adjustment) { build(:payroll_adjustment) }

  describe "validations" do
    it { is_expected.to be_valid }
    it { is_expected.to validate_presence_of(:reason) }

    it "requires amount to be greater than zero" do
      adjustment.amount = 0
      expect(adjustment).not_to be_valid
      adjustment.amount = -1
      expect(adjustment).not_to be_valid
    end

    it "rejects unknown adjustment_type" do
      expect { adjustment.adjustment_type = "unknown" }.to raise_error(ArgumentError)
    end
  end

  describe "#signed_amount" do
    it "returns positive amount for bonus" do
      adjustment.adjustment_type = :bonus
      adjustment.amount = 300.0
      expect(adjustment.signed_amount).to eq(300.0)
    end

    it "returns negative amount for manual_deduction" do
      adjustment.adjustment_type = :manual_deduction
      adjustment.amount = 200.0
      expect(adjustment.signed_amount).to eq(-200.0)
    end
  end

  describe "associations" do
    it { is_expected.to belong_to(:payroll_period).optional }
    it { is_expected.to belong_to(:user) }
    it { is_expected.to belong_to(:created_by).class_name("User") }
  end
end
