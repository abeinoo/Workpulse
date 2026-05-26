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

    describe "user_belongs_to_business" do
      it "is valid when user belongs to the same business" do
        expect(adjustment).to be_valid
      end

      it "is invalid when user belongs to a different business" do
        adjustment.user = create(:user, business: create(:business))
        expect(adjustment).not_to be_valid
        expect(adjustment.errors[:user]).to be_present
      end
    end
  end

  describe "#signed_amount" do
    it "returns positive amount for cash_incentive" do
      adjustment.adjustment_type = :cash_incentive
      adjustment.amount = 300.0
      expect(adjustment.signed_amount).to eq(300.0)
    end

    it "returns negative amount for manual_deduction" do
      adjustment.adjustment_type = :manual_deduction
      adjustment.amount = 200.0
      expect(adjustment.signed_amount).to eq(-200.0)
    end
  end

  describe "#line_item_type" do
    it "returns the current adjustment_type for normal records" do
      adjustment.adjustment_type = :cash_incentive
      expect(adjustment.line_item_type).to eq("cash_incentive")
    end

    it "returns commission unchanged" do
      adjustment.adjustment_type = :commission
      expect(adjustment.line_item_type).to eq("commission")
    end

    it "maps legacy 'bonus' to 'cash_incentive' via raw DB value" do
      # Simulate a DB row that predates the enum consolidation.
      # write_attribute bypasses the enum type-cast so the raw string is stored.
      adjustment.save!
      adjustment.class.where(id: adjustment.id).update_all(adjustment_type: "bonus")
      reloaded = PayrollAdjustment.find(adjustment.id)
      expect(reloaded.line_item_type).to eq("cash_incentive")
    end

    it "maps legacy 'reward' to 'cash_incentive'" do
      adjustment.save!
      adjustment.class.where(id: adjustment.id).update_all(adjustment_type: "reward")
      reloaded = PayrollAdjustment.find(adjustment.id)
      expect(reloaded.line_item_type).to eq("cash_incentive")
    end

    it "maps legacy 'eid_bonus' to 'cash_incentive'" do
      adjustment.save!
      adjustment.class.where(id: adjustment.id).update_all(adjustment_type: "eid_bonus")
      reloaded = PayrollAdjustment.find(adjustment.id)
      expect(reloaded.line_item_type).to eq("cash_incentive")
    end
  end

  describe "associations" do
    it { is_expected.to belong_to(:payroll_period).optional }
    it { is_expected.to belong_to(:user) }
    it { is_expected.to belong_to(:created_by).class_name("User") }
  end
end
