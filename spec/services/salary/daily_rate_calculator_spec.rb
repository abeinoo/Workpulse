require "rails_helper"

RSpec.describe Salary::DailyRateCalculator do
  let(:business) { create(:business, working_days_per_month: 22) }
  let(:user)     { create(:user, business: business) }

  def calculator(date: Date.current)
    described_class.for(user: user, business: business, date: date)
  end

  describe "with no salary profile" do
    it "#daily_rate returns 0.0" do
      expect(calculator.daily_rate).to eq(0.0)
    end

    it "#monthly_equivalent returns 0.0" do
      expect(calculator.monthly_equivalent).to eq(0.0)
    end

    it "#profile returns nil" do
      expect(calculator.profile).to be_nil
    end
  end

  describe "with a monthly salary profile (SAR 5,000 / 22 days)" do
    before { create(:salary_profile, :monthly, user: user, base_amount: 5_000.0) }

    it "#daily_rate returns 5000 / 22 rounded to 4 decimal places" do
      expect(calculator.daily_rate).to be_within(0.0001).of(227.2727)
    end

    it "#monthly_equivalent returns the base amount" do
      expect(calculator.monthly_equivalent).to eq(5_000.0)
    end

    describe "#hourly_rate" do
      let(:shift) { build(:shift, :fixed_time,
                          start_time: Time.zone.parse("09:00"),
                          end_time:   Time.zone.parse("17:00")) }

      it "returns daily_rate divided by shift hours" do
        expected = (calculator.daily_rate / 8.0).round(4)
        expect(calculator.hourly_rate(shift)).to be_within(0.0001).of(expected)
      end
    end
  end

  describe "with a daily salary profile (SAR 250/day)" do
    before { create(:salary_profile, :daily, user: user, base_amount: 250.0) }

    it "#daily_rate returns the base amount directly" do
      expect(calculator.daily_rate).to eq(250.0)
    end

    it "#monthly_equivalent returns daily_rate * working_days_per_month" do
      expect(calculator.monthly_equivalent).to eq(5_500.0)
    end
  end

  describe "historical date lookup" do
    it "returns 0 if the only active profile has a future effective_from" do
      create(:salary_profile, :monthly, user: user, base_amount: 5_000.0,
             effective_from: 1.month.from_now.to_date)
      expect(calculator.daily_rate).to eq(0.0)
    end

    it "selects the profile that was active on the given past date" do
      old = create(:salary_profile, :monthly, user: user, base_amount: 3_000.0,
                   effective_from: 2.years.ago.to_date)
      _recent = create(:salary_profile, :monthly, user: user, base_amount: 5_000.0,
                       effective_from: 1.month.ago.to_date)

      calc = described_class.for(user: user, business: business,
                                 date: 3.months.ago.to_date)
      expect(calc.profile).to eq(old)
    end
  end
end
