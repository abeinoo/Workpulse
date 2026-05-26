require "rails_helper"

RSpec.describe Employee::PerformanceScorer do
  let(:business) { create(:business, working_days_per_month: 22) }
  let(:user)     { create(:user, business: business) }
  let(:from)     { Date.current.beginning_of_month }
  let(:to)       { [from + 21.days, Date.current].min }

  def scorer_with_records(records)
    instance = described_class.new(user: user, from: from, to: to)
    allow(AttendanceRecord).to receive(:where).with(user: user, work_date: from..to).and_return(records)
    instance
  end

  subject(:result) { described_class.call(user: user, from: from, to: to) }

  context "with no attendance records" do
    before do
      allow(AttendanceRecord).to receive(:where).with(user: user, work_date: from..to)
                                                .and_return(AttendanceRecord.none)
    end

    it "returns a score between 0 and 100" do
      expect(result.score).to be_between(0, 100)
    end

    it "returns a valid grade" do
      expect(described_class::GRADE_MAP.values).to include(result.grade)
    end
  end

  context "with perfect attendance (all present + checked out)" do
    let(:records) do
      5.times.map { |i|
        build_stubbed(:attendance_record,
          status:       "present",
          late_minutes: 0,
          early_leave_minutes: 0,
          check_in_at:  (from + i.days).to_time.change(hour: 9),
          check_out_at: (from + i.days).to_time.change(hour: 17),
          worked_minutes: 480
        )
      }
    end

    before do
      allow(AttendanceRecord).to receive(:where).with(user: user, work_date: from..to)
                                                .and_return(records)
    end

    it "returns a score > 50" do
      expect(result.score).to be > 50
    end

    it "has no late days" do
      expect(result.late_days).to eq(0)
    end

    it "has no incomplete days" do
      expect(result.incomplete_days).to eq(0)
    end
  end

  context "with many late arrivals" do
    let(:records) do
      5.times.map { |i|
        build_stubbed(:attendance_record,
          status:       "late",
          late_minutes: 45,
          check_in_at:  (from + i.days).to_time.change(hour: 9, min: 45)
        )
      }
    end

    before do
      allow(AttendanceRecord).to receive(:where).with(user: user, work_date: from..to)
                                                .and_return(records)
    end

    it "reports late days correctly" do
      expect(result.late_days).to eq(5)
    end
  end

  describe "grade mapping" do
    it "maps score 95 to excellent" do
      grade = described_class::GRADE_MAP.find { |range, _| range.cover?(95) }&.last
      expect(grade).to eq(:excellent)
    end

    it "maps score 80 to good" do
      grade = described_class::GRADE_MAP.find { |range, _| range.cover?(80) }&.last
      expect(grade).to eq(:good)
    end

    it "maps score 30 to poor" do
      grade = described_class::GRADE_MAP.find { |range, _| range.cover?(30) }&.last
      expect(grade).to eq(:poor)
    end
  end

  describe "breakdown keys" do
    before do
      allow(AttendanceRecord).to receive(:where).with(user: user, work_date: from..to)
                                                .and_return(AttendanceRecord.none)
    end

    it "includes all expected dimensions" do
      expected = %i[attendance_consistency lateness_frequency shift_completion
                    overtime_reliability absence_rate]
      expect(result.breakdown.keys).to match_array(expected)
    end

    it "sums breakdown components to match total score" do
      expect(result.breakdown.values.sum).to eq(result.score)
    end
  end
end
