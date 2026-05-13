require "rails_helper"

RSpec.describe Salary::OvertimeCalculator do
  let(:business) { create(:business, working_days_per_month: 22) }
  let(:user)     { create(:user, business: business) }
  let(:branch)   { create(:branch, business: business) }

  # 8-hour fixed shift with 1.5x overtime multiplier
  let(:shift) do
    create(:shift, :fixed_time, business: business,
           start_time: Time.zone.parse("09:00"),
           end_time:   Time.zone.parse("17:00"),
           overtime_rate_multiplier: 1.5)
  end

  let(:shift_assignment) do
    create(:shift_assignment, user: user, branch: branch, shift: shift,
           effective_from: 1.month.ago.to_date)
  end

  # Monthly 8,800 SAR / 22 days = 400/day
  let(:daily_rate) { 400.0 }

  def build_record(worked_minutes:, status: "present")
    build(:attendance_record,
          user:             user,
          branch:           branch,
          shift_assignment: shift_assignment,
          worked_minutes:   worked_minutes,
          status:           status)
  end

  describe ".calculate" do
    context "when worked minutes equals shift duration (no overtime)" do
      it "returns zero overtime" do
        result = described_class.calculate(record: build_record(worked_minutes: 480), daily_rate: daily_rate)
        expect(result.overtime_minutes).to eq(0)
        expect(result.overtime_pay).to eq(0.0)
      end
    end

    context "when worked minutes is less than shift duration" do
      it "returns zero overtime" do
        result = described_class.calculate(record: build_record(worked_minutes: 400), daily_rate: daily_rate)
        expect(result.overtime_minutes).to eq(0)
        expect(result.overtime_pay).to eq(0.0)
      end
    end

    context "when worked 60 minutes of overtime" do
      it "returns 60 overtime minutes" do
        result = described_class.calculate(record: build_record(worked_minutes: 540), daily_rate: daily_rate)
        expect(result.overtime_minutes).to eq(60)
      end

      it "calculates pay as hourly_rate * overtime_hours * multiplier" do
        # hourly_rate = 400 / 8 = 50 SAR/hr
        # overtime_pay = 50 * 1.0 * 1.5 = 75 SAR
        result = described_class.calculate(record: build_record(worked_minutes: 540), daily_rate: daily_rate)
        expect(result.overtime_pay).to eq(75.0)
      end
    end

    context "when worked 90 minutes of overtime" do
      it "returns 90 overtime minutes and correct pay" do
        # 90 min = 1.5 hrs * 50 SAR/hr * 1.5x = 112.5 SAR
        result = described_class.calculate(record: build_record(worked_minutes: 570), daily_rate: daily_rate)
        expect(result.overtime_minutes).to eq(90)
        expect(result.overtime_pay).to eq(112.5)
      end
    end

    context "when worked_minutes is zero" do
      it "returns zero result" do
        result = described_class.calculate(record: build_record(worked_minutes: 0), daily_rate: daily_rate)
        expect(result.overtime_pay).to eq(0.0)
      end
    end

    context "when record has no shift assignment" do
      it "returns zero result" do
        record = build(:attendance_record, user: user, branch: branch,
                       shift_assignment: shift_assignment, worked_minutes: 600)
        allow(record).to receive(:shift_assignment).and_return(nil)
        result = described_class.calculate(record: record, daily_rate: daily_rate)
        expect(result.overtime_pay).to eq(0.0)
      end
    end

    context "with hour_based shift (8 required hours, 1.25x multiplier)" do
      let(:flex_shift) do
        create(:shift, :hour_based, business: business,
               required_hours: 8,
               overtime_rate_multiplier: 1.25)
      end

      let(:flex_assignment) do
        create(:shift_assignment, user: user, branch: branch, shift: flex_shift,
               effective_from: 1.month.ago.to_date)
      end

      it "calculates overtime using required_hours as baseline" do
        record = build(:attendance_record, user: user, branch: branch,
                       shift_assignment: flex_assignment, worked_minutes: 540)
        # 60 min overtime, hourly = 400/8 = 50, pay = 50 * 1.0 * 1.25 = 62.5
        result = described_class.calculate(record: record, daily_rate: daily_rate)
        expect(result.overtime_minutes).to eq(60)
        expect(result.overtime_pay).to eq(62.5)
      end
    end
  end
end
