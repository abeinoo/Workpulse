require "rails_helper"

RSpec.describe Salary::OvertimeCalculator do
  let(:business) { create(:business, working_days_per_month: 22) }
  let(:user)     { create(:user, business: business) }
  let(:branch)   { create(:branch, business: business) }

  # 8-hour fixed shift (480 min) with 1.5x overtime multiplier
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

  # ── No grace (backward-compatible default) ────────────────────────────────

  describe ".calculate without grace_minutes (default = 0)" do
    context "when worked equals shift duration" do
      it "returns zero overtime" do
        result = described_class.calculate(record: build_record(worked_minutes: 480), daily_rate: daily_rate)
        expect(result.overtime_minutes).to eq(0)
        expect(result.overtime_pay).to eq(0.0)
      end
    end

    context "when worked is less than shift duration" do
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
  end

  # ── Grace threshold: 30 minutes (eligibility gate, not a deduction) ───────
  #
  # Shift ends 17:00 (480 scheduled min). grace_minutes is the minimum raw
  # overtime required before ANY overtime counts. Once reached, ALL raw
  # minutes past shift end count — the threshold itself is included.

  describe ".calculate with grace_minutes: 30" do
    let(:grace) { 30 }

    context "when employee leaves exactly at shift end (0 min past)" do
      it "returns zero overtime" do
        result = described_class.calculate(
          record: build_record(worked_minutes: 480), daily_rate: daily_rate, grace_minutes: grace
        )
        expect(result.overtime_minutes).to eq(0)
        expect(result.overtime_pay).to eq(0.0)
      end
    end

    context "when employee leaves 10 minutes past shift end (well below threshold)" do
      it "returns zero overtime" do
        result = described_class.calculate(
          record: build_record(worked_minutes: 490), daily_rate: daily_rate, grace_minutes: grace
        )
        expect(result.overtime_minutes).to eq(0)
        expect(result.overtime_pay).to eq(0.0)
      end
    end

    context "when employee leaves 29 minutes past shift end (1 min below threshold)" do
      it "returns zero overtime" do
        result = described_class.calculate(
          record: build_record(worked_minutes: 509), daily_rate: daily_rate, grace_minutes: grace
        )
        expect(result.overtime_minutes).to eq(0)
        expect(result.overtime_pay).to eq(0.0)
      end
    end

    context "when employee leaves exactly at the threshold (30 min past end)" do
      it "counts the full 30 minutes — the threshold is included, not subtracted" do
        result = described_class.calculate(
          record: build_record(worked_minutes: 510), daily_rate: daily_rate, grace_minutes: grace
        )
        expect(result.overtime_minutes).to eq(30)
        # hourly = 400 / 8 = 50; pay = 50 * (30/60) * 1.5 = 37.5
        expect(result.overtime_pay).to eq(37.5)
      end
    end

    context "when employee leaves 31 minutes past shift end (1 min beyond threshold)" do
      it "counts the full 31 minutes" do
        result = described_class.calculate(
          record: build_record(worked_minutes: 511), daily_rate: daily_rate, grace_minutes: grace
        )
        expect(result.overtime_minutes).to eq(31)
      end
    end

    context "when employee leaves 45 minutes past shift end" do
      it "counts the full 45 minutes with correct pay" do
        # hourly = 400 / 8 = 50; pay = 50 * (45/60) * 1.5 = 56.25
        result = described_class.calculate(
          record: build_record(worked_minutes: 525), daily_rate: daily_rate, grace_minutes: grace
        )
        expect(result.overtime_minutes).to eq(45)
        expect(result.overtime_pay).to eq(56.25)
      end
    end

    context "when employee works 2.5 hours past shift end" do
      it "counts the full raw overtime, not just the amount beyond the threshold" do
        # worked = 480 + 150 = 630; overtime = 150 (NOT 630 - 480 - 30 = 120)
        # pay = 50 * 2.5 * 1.5 = 187.5
        result = described_class.calculate(
          record: build_record(worked_minutes: 630), daily_rate: daily_rate, grace_minutes: grace
        )
        expect(result.overtime_minutes).to eq(150)
        expect(result.overtime_pay).to eq(187.5)
      end
    end
  end

  # ── Grace threshold: 15 minutes ───────────────────────────────────────────

  describe ".calculate with grace_minutes: 15" do
    let(:grace) { 15 }

    context "when 14 minutes past shift end (below threshold)" do
      it "returns zero overtime" do
        result = described_class.calculate(
          record: build_record(worked_minutes: 494), daily_rate: daily_rate, grace_minutes: grace
        )
        expect(result.overtime_minutes).to eq(0)
      end
    end

    context "when exactly 15 minutes past shift end (at threshold)" do
      it "counts the full 15 minutes" do
        result = described_class.calculate(
          record: build_record(worked_minutes: 495), daily_rate: daily_rate, grace_minutes: grace
        )
        expect(result.overtime_minutes).to eq(15)
      end
    end

    context "when 16 minutes past shift end (1 min beyond threshold)" do
      it "counts the full 16 minutes" do
        result = described_class.calculate(
          record: build_record(worked_minutes: 496), daily_rate: daily_rate, grace_minutes: grace
        )
        expect(result.overtime_minutes).to eq(16)
      end
    end
  end

  # ── Grace threshold: 60 minutes ───────────────────────────────────────────

  describe ".calculate with grace_minutes: 60" do
    let(:grace) { 60 }

    context "when 59 minutes past shift end (below threshold)" do
      it "returns zero overtime" do
        result = described_class.calculate(
          record: build_record(worked_minutes: 539), daily_rate: daily_rate, grace_minutes: grace
        )
        expect(result.overtime_minutes).to eq(0)
      end
    end

    context "when exactly 60 minutes past shift end (at threshold)" do
      it "counts the full 60 minutes" do
        result = described_class.calculate(
          record: build_record(worked_minutes: 540), daily_rate: daily_rate, grace_minutes: grace
        )
        expect(result.overtime_minutes).to eq(60)
      end
    end

    context "when 61 minutes past shift end" do
      it "counts the full 61 minutes" do
        result = described_class.calculate(
          record: build_record(worked_minutes: 541), daily_rate: daily_rate, grace_minutes: grace
        )
        expect(result.overtime_minutes).to eq(61)
      end
    end
  end

  # ── Grace threshold: 0 (no grace — original behaviour) ───────────────────

  describe ".calculate with explicit grace_minutes: 0" do
    it "is identical to calling without grace_minutes" do
      record = build_record(worked_minutes: 510)
      result_implicit = described_class.calculate(record: record, daily_rate: daily_rate)
      result_explicit = described_class.calculate(record: record, daily_rate: daily_rate, grace_minutes: 0)
      expect(result_explicit.overtime_minutes).to eq(result_implicit.overtime_minutes)
      expect(result_explicit.overtime_pay).to eq(result_implicit.overtime_pay)
    end

    it "counts every minute past shift end as overtime" do
      result = described_class.calculate(
        record: build_record(worked_minutes: 481), daily_rate: daily_rate, grace_minutes: 0
      )
      expect(result.overtime_minutes).to eq(1)
    end
  end

  # ── Hour-based (flexible) shifts ──────────────────────────────────────────

  describe "with hour_based shift (8 required hours, 1.25x multiplier)" do
    let(:flex_shift) do
      create(:shift, :hour_based, business: business,
             required_hours: 8,
             overtime_rate_multiplier: 1.25)
    end

    let(:flex_assignment) do
      create(:shift_assignment, user: user, branch: branch, shift: flex_shift,
             effective_from: 1.month.ago.to_date)
    end

    def build_flex_record(worked_minutes:)
      build(:attendance_record, user: user, branch: branch,
            shift_assignment: flex_assignment, worked_minutes: worked_minutes)
    end

    context "without grace" do
      it "calculates overtime using required_hours as baseline" do
        record = build_flex_record(worked_minutes: 540)
        # 60 min overtime, hourly = 400/8 = 50, pay = 50 * 1.0 * 1.25 = 62.5
        result = described_class.calculate(record: record, daily_rate: daily_rate)
        expect(result.overtime_minutes).to eq(60)
        expect(result.overtime_pay).to eq(62.5)
      end
    end

    context "with grace_minutes: 30" do
      it "applies the eligibility threshold to flexible shifts the same way as fixed shifts" do
        # worked = 520 (40 min past required, >= 30 threshold); full 40 min counted
        record = build_flex_record(worked_minutes: 520)
        result = described_class.calculate(record: record, daily_rate: daily_rate, grace_minutes: 30)
        expect(result.overtime_minutes).to eq(40)
      end

      it "returns zero when below the threshold on a flex shift" do
        # worked = 509 (29 min past required, < 30 threshold) → 0
        record = build_flex_record(worked_minutes: 509)
        result = described_class.calculate(record: record, daily_rate: daily_rate, grace_minutes: 30)
        expect(result.overtime_minutes).to eq(0)
      end

      it "counts the full amount at exactly the threshold on a flex shift" do
        # worked = 510 (30 min past required, at threshold) → 30
        record = build_flex_record(worked_minutes: 510)
        result = described_class.calculate(record: record, daily_rate: daily_rate, grace_minutes: 30)
        expect(result.overtime_minutes).to eq(30)
      end
    end
  end

  # ── Custom multiplier override ─────────────────────────────────────────────

  describe "custom multiplier parameter" do
    it "overrides shift.overtime_rate_multiplier" do
      # Shift has 1.5x, override with 2.0x
      # 60 min OT; hourly = 50; pay = 50 * 1.0 * 2.0 = 100
      result = described_class.calculate(
        record:     build_record(worked_minutes: 540),
        daily_rate: daily_rate,
        multiplier: 2.0
      )
      expect(result.overtime_pay).to eq(100.0)
    end
  end
end
