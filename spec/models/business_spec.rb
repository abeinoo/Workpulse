require "rails_helper"

RSpec.describe Business, type: :model do
  subject { build(:business) }

  describe "associations" do
    it { is_expected.to have_many(:branches).dependent(:destroy) }
    it { is_expected.to have_many(:users).dependent(:destroy) }
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
