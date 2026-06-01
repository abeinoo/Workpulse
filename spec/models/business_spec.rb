require "rails_helper"

RSpec.describe Business, type: :model do
  subject { build(:business) }

  describe "associations" do
    it { is_expected.to have_many(:branches).dependent(:destroy) }
    it { is_expected.to have_many(:users).dependent(:destroy) }
    it { is_expected.to have_many(:permission_roles).dependent(:destroy) }
    it { is_expected.to have_many(:shifts).dependent(:destroy) }
    it { is_expected.to have_many(:payroll_periods).dependent(:destroy) }
  end

  describe "validations" do
    it { is_expected.to validate_presence_of(:name) }
    it { is_expected.to validate_presence_of(:timezone) }

    describe "working_days_per_month" do
      it "must be greater than zero" do
        expect(build(:business, working_days_per_month: 0)).not_to be_valid
      end

      it "must not exceed 31" do
        expect(build(:business, working_days_per_month: 32)).not_to be_valid
      end

      it "accepts 22 (typical value)" do
        expect(build(:business, working_days_per_month: 22)).to be_valid
      end
    end

    describe "employee_code_start" do
      it "defaults to 1" do
        expect(create(:business).employee_code_start).to eq(1)
      end

      it "rejects values below 1" do
        expect(build(:business, employee_code_start: 0)).not_to be_valid
      end

      it "rejects non-integer values" do
        expect(build(:business, employee_code_start: 1.5)).not_to be_valid
      end

      it "accepts a positive integer" do
        expect(build(:business, employee_code_start: 500)).to be_valid
      end
    end
  end

  describe "#next_employee_code" do
    it "returns the starting number when no codes exist yet" do
      business = create(:business, employee_code_start: 500)
      expect(business.next_employee_code).to eq(500)
    end

    it "returns one above the highest existing numeric code" do
      business = create(:business, employee_code_start: 1)
      create(:user, business: business, employee_code: "500")
      create(:user, business: business, employee_code: "700")
      expect(business.next_employee_code).to eq(701)
    end

    it "ignores non-numeric codes" do
      business = create(:business, employee_code_start: 1)
      create(:user, business: business, employee_code: "EMP-001")
      create(:user, business: business, employee_code: "42")
      expect(business.next_employee_code).to eq(43)
    end

    it "never returns below the starting number" do
      business = create(:business, employee_code_start: 500)
      create(:user, business: business, employee_code: "100")
      expect(business.next_employee_code).to eq(500)
    end
  end

  describe "#timezone_object" do
    it "returns an ActiveSupport::TimeZone for a known timezone" do
      biz = build(:business, timezone: "Asia/Riyadh")
      expect(biz.timezone_object).to be_a(ActiveSupport::TimeZone)
      expect(biz.timezone_object.name).to eq("Asia/Riyadh")
    end

    it "falls back to UTC for an unrecognised timezone string" do
      biz = build(:business, timezone: "Not/Real")
      expect(biz.timezone_object.name).to eq("UTC")
    end
  end
end
