require "rails_helper"

RSpec.describe Employee, type: :model do
  describe "associations" do
    it { is_expected.to have_one(:user) }
    it { is_expected.to belong_to(:manager).optional }
    it { is_expected.to have_many(:subordinates) }
  end

  describe "validations" do
    subject { build(:employee) }

    it { is_expected.to validate_presence_of(:phone_number) }

    it "rejects a duplicate phone number" do
      create(:employee, phone_number: "+966050000001")
      duplicate = build(:employee, phone_number: "+966050000001")
      expect(duplicate).not_to be_valid
    end
    it { is_expected.to validate_presence_of(:employee_number) }
    it { is_expected.to validate_uniqueness_of(:employee_number) }
    it { is_expected.to validate_presence_of(:full_name) }

    context "email format" do
      it "accepts a valid email" do
        expect(build(:employee, email: "valid@example.com")).to be_valid
      end

      it "rejects an invalid email" do
        expect(build(:employee, email: "not-an-email")).not_to be_valid
      end

      it "allows nil email" do
        expect(build(:employee, email: nil)).to be_valid
      end
    end
  end

  describe "#normalize_phone_number" do
    it "strips spaces from a number with international prefix" do
      employee = build(:employee, phone_number: "+966 05 123 4567")
      employee.valid?
      expect(employee.phone_number).to eq("+966051234567")
    end

    it "strips hyphens and parentheses" do
      employee = build(:employee, phone_number: "+966-(05)-123-4567")
      employee.valid?
      expect(employee.phone_number).to eq("+966051234567")
    end

    it "preserves the leading + when present" do
      employee = build(:employee, phone_number: "+1 800 555 0100")
      employee.valid?
      expect(employee.phone_number).to start_with("+")
    end

    it "omits + when not present in original" do
      employee = build(:employee, phone_number: "0512345678")
      employee.valid?
      expect(employee.phone_number).to eq("0512345678")
    end

    it "does nothing when phone_number is blank" do
      employee = build(:employee, phone_number: "")
      employee.valid?
      expect(employee.phone_number).to eq("")
    end
  end
end
