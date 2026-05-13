require "rails_helper"

RSpec.describe Attendance::PenaltyCalculator do
  let(:business) { create(:business) }
  let(:branch)   { create(:branch, business: business) }
  let(:shift)    { create(:shift, :fixed_time, business: business) }
  let(:user)     { create(:user, business: business) }

  # Base daily salary for percentage calculations
  let(:daily_salary) { 250.0 }

  let(:assignment) do
    create(:shift_assignment, user: user, branch: branch, shift: shift,
           effective_from: 1.month.ago.to_date)
  end

  def build_record(late_minutes: 0, early_leave_minutes: 0)
    build(:attendance_record,
          user:               user,
          branch:             branch,
          shift_assignment:   assignment,
          late_minutes:       late_minutes,
          early_leave_minutes: early_leave_minutes)
  end

  def calculate(record)
    described_class.calculate(record: record, daily_salary: daily_salary)
  end

  describe "with no penalty rules on the shift" do
    it "returns zero penalties" do
      result = calculate(build_record(late_minutes: 60))
      expect(result.late_penalty).to eq(0.0)
      expect(result.early_leave_penalty).to eq(0.0)
      expect(result.total_deduction).to eq(0.0)
    end
  end

  describe "fixed_amount late arrival penalty" do
    before do
      create(:penalty_rule, shift: shift, rule_type: :late_arrival,
             threshold_minutes: 15, deduction_type: :fixed_amount, deduction_value: 50)
    end

    it "applies the penalty when late_minutes exceeds the threshold" do
      result = calculate(build_record(late_minutes: 30))
      expect(result.late_penalty).to eq(50.0)
    end

    it "returns 0 when late_minutes is below the threshold" do
      result = calculate(build_record(late_minutes: 10))
      expect(result.late_penalty).to eq(0.0)
    end

    it "applies penalty at exactly the threshold" do
      result = calculate(build_record(late_minutes: 15))
      expect(result.late_penalty).to eq(50.0)
    end
  end

  describe "percentage_of_daily late arrival penalty" do
    before do
      create(:penalty_rule, shift: shift, rule_type: :late_arrival,
             threshold_minutes: 15, deduction_type: :percentage_of_daily, deduction_value: 10)
    end

    it "deducts 10% of the daily salary" do
      result = calculate(build_record(late_minutes: 20))
      expect(result.late_penalty).to eq(25.0) # 250 * 10% = 25
    end
  end

  describe "tiered penalty rules" do
    before do
      create(:penalty_rule, shift: shift, rule_type: :late_arrival,
             threshold_minutes: 15, deduction_type: :fixed_amount, deduction_value: 50)
      create(:penalty_rule, shift: shift, rule_type: :late_arrival,
             threshold_minutes: 60, deduction_type: :fixed_amount, deduction_value: 150)
    end

    it "applies the highest matching tier" do
      result = calculate(build_record(late_minutes: 90))
      expect(result.late_penalty).to eq(150.0)
    end

    it "applies the lower tier when not reaching the higher threshold" do
      result = calculate(build_record(late_minutes: 30))
      expect(result.late_penalty).to eq(50.0)
    end
  end

  describe "early_leave penalty" do
    before do
      create(:penalty_rule, shift: shift, rule_type: :early_leave,
             threshold_minutes: 30, deduction_type: :fixed_amount, deduction_value: 80)
    end

    it "applies the early_leave penalty correctly" do
      result = calculate(build_record(early_leave_minutes: 45))
      expect(result.early_leave_penalty).to eq(80.0)
    end

    it "does not apply late_arrival rules for early_leave minutes" do
      result = calculate(build_record(early_leave_minutes: 45))
      expect(result.late_penalty).to eq(0.0)
    end
  end

  describe "total_deduction" do
    before do
      create(:penalty_rule, shift: shift, rule_type: :late_arrival,
             threshold_minutes: 15, deduction_type: :fixed_amount, deduction_value: 50)
      create(:penalty_rule, shift: shift, rule_type: :early_leave,
             threshold_minutes: 30, deduction_type: :fixed_amount, deduction_value: 80)
    end

    it "sums late and early_leave penalties" do
      result = calculate(build_record(late_minutes: 20, early_leave_minutes: 45))
      expect(result.total_deduction).to eq(130.0)
    end
  end
end
