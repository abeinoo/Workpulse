require "rails_helper"

RSpec.describe Attendance::TimeCalculator do
  # Use UTC so Time.zone.parse times need no offset conversion in the calculator
  let(:business) { create(:business, timezone: "UTC") }
  let(:branch)   { create(:branch, business: business) }

  describe ".late_minutes" do
    context "fixed_time shift (09:00–17:00)" do
      let(:shift) { build(:shift, :fixed_time, start_time: Time.zone.parse("09:00")) }

      it "returns 0 when checking in exactly on time" do
        check_in = Time.zone.parse("2025-04-01 09:00:00")
        expect(described_class.late_minutes(shift, check_in, branch)).to eq(0)
      end

      it "returns 0 when checking in before shift start" do
        check_in = Time.zone.parse("2025-04-01 08:30:00")
        expect(described_class.late_minutes(shift, check_in, branch)).to eq(0)
      end

      it "returns correct minutes when late" do
        check_in = Time.zone.parse("2025-04-01 09:45:00")
        expect(described_class.late_minutes(shift, check_in, branch)).to eq(45)
      end
    end

    context "hour_based shift" do
      let(:shift) { build(:shift, :hour_based, required_hours: 8.0) }

      it "always returns 0 (no fixed start time to be late for)" do
        check_in = Time.zone.parse("2025-04-01 11:00:00")
        expect(described_class.late_minutes(shift, check_in, branch)).to eq(0)
      end
    end
  end

  describe ".early_leave_minutes" do
    context "fixed_time shift ending at 17:00" do
      let(:shift) { build(:shift, :fixed_time, end_time: Time.zone.parse("17:00")) }

      it "returns 0 when checking out at end time" do
        check_out = Time.zone.parse("2025-04-01 17:00:00")
        expect(described_class.early_leave_minutes(shift, check_out, 480, branch)).to eq(0)
      end

      it "returns 0 when checking out after end time" do
        check_out = Time.zone.parse("2025-04-01 17:30:00")
        expect(described_class.early_leave_minutes(shift, check_out, 510, branch)).to eq(0)
      end

      it "returns the shortfall minutes when leaving early" do
        check_out = Time.zone.parse("2025-04-01 15:00:00")
        expect(described_class.early_leave_minutes(shift, check_out, 360, branch)).to eq(120)
      end
    end

    context "hour_based shift requiring 8 hours" do
      let(:shift) { build(:shift, :hour_based, required_hours: 8.0) }

      it "returns 0 when worked minutes equal required" do
        expect(described_class.early_leave_minutes(shift, Time.current, 480, branch)).to eq(0)
      end

      it "returns the shortfall when worked fewer than required hours" do
        expect(described_class.early_leave_minutes(shift, Time.current, 360, branch)).to eq(120)
      end
    end

    context "overnight shift (13:00 → 01:00)" do
      let(:shift) { build(:shift, :overnight, business: business) }

      it "returns 0 when checking out exactly at shift end (01:00 next day)" do
        check_out = Time.zone.parse("2025-04-02 01:00:00")
        expect(described_class.early_leave_minutes(shift, check_out, 720, branch)).to eq(0)
      end

      it "returns 0 when checking out after shift end (01:30 next day)" do
        check_out = Time.zone.parse("2025-04-02 01:30:00")
        expect(described_class.early_leave_minutes(shift, check_out, 750, branch)).to eq(0)
      end

      it "returns 120 when leaving early in the evening (23:00, shift ends 01:00)" do
        check_out = Time.zone.parse("2025-04-01 23:00:00")
        expect(described_class.early_leave_minutes(shift, check_out, 600, branch)).to eq(120)
      end

      it "returns 30 when leaving 30 min early in the morning (00:30, shift ends 01:00)" do
        check_out = Time.zone.parse("2025-04-02 00:30:00")
        expect(described_class.early_leave_minutes(shift, check_out, 690, branch)).to eq(30)
      end
    end

    context "when check_out_at is nil" do
      let(:shift) { build(:shift, :fixed_time) }

      it "returns 0" do
        expect(described_class.early_leave_minutes(shift, nil, 0, branch)).to eq(0)
      end
    end
  end

  # January dates: Africa/Cairo is EET (UTC+2, no DST).
  # In summer, Cairo observes EEST (UTC+3) which would shift these UTC values by one extra hour.
  describe "non-UTC business timezone (Africa/Cairo, UTC+2 in winter)" do
    let(:cairo_business) { create(:business, timezone: "Africa/Cairo") }
    let(:cairo_branch)   { create(:branch, business: cairo_business) }

    describe ".late_minutes with UTC+2 timezone" do
      let(:shift) { build(:shift, :fixed_time, start_time: Time.zone.parse("09:00"), business: cairo_business) }

      it "returns 0 when check_in_at is 07:00 UTC (= 09:00 Cairo EET)" do
        check_in = Time.utc(2026, 1, 24, 7, 0, 0)
        expect(described_class.late_minutes(shift, check_in, cairo_branch)).to eq(0)
      end

      it "returns 30 when check_in_at is 07:30 UTC (= 09:30 Cairo EET)" do
        check_in = Time.utc(2026, 1, 24, 7, 30, 0)
        expect(described_class.late_minutes(shift, check_in, cairo_branch)).to eq(30)
      end

      it "returns 0 when check_in_at is 06:45 UTC (= 08:45 Cairo EET, early)" do
        check_in = Time.utc(2026, 1, 24, 6, 45, 0)
        expect(described_class.late_minutes(shift, check_in, cairo_branch)).to eq(0)
      end
    end

    describe ".early_leave_minutes with UTC+2 timezone" do
      let(:shift) { build(:shift, :fixed_time, end_time: Time.zone.parse("17:00"), business: cairo_business) }

      it "returns 0 when check_out_at is 15:00 UTC (= 17:00 Cairo EET, on time)" do
        check_out = Time.utc(2026, 1, 24, 15, 0, 0)
        expect(described_class.early_leave_minutes(shift, check_out, 480, cairo_branch)).to eq(0)
      end

      it "returns 120 when check_out_at is 13:00 UTC (= 15:00 Cairo EET, 2h early)" do
        check_out = Time.utc(2026, 1, 24, 13, 0, 0)
        expect(described_class.early_leave_minutes(shift, check_out, 360, cairo_branch)).to eq(120)
      end
    end
  end

  describe ".overtime_minutes" do
    let(:shift) { build(:shift, :fixed_time, start_time: Time.zone.parse("09:00"), end_time: Time.zone.parse("17:00")) }
    # 09:00–17:00 → 480 scheduled minutes

    it "returns 0 when worked does not exceed scheduled + grace" do
      expect(described_class.overtime_minutes(shift, 480, overtime_grace_minutes: 30)).to eq(0)
      expect(described_class.overtime_minutes(shift, 500, overtime_grace_minutes: 30)).to eq(0) # 20 over, < 30 grace
    end

    it "counts minutes beyond scheduled + grace" do
      expect(described_class.overtime_minutes(shift, 525, overtime_grace_minutes: 30)).to eq(15) # 45 over - 30 grace
    end

    it "returns 0 when the rule profile disables overtime" do
      profile = build(:shift_rule_profile, overtime_enabled: false)
      expect(described_class.overtime_minutes(shift, 600, overtime_grace_minutes: 0, rule_profile: profile)).to eq(0)
    end

    it "deducts rule-profile break minutes from worked first" do
      profile = build(:shift_rule_profile, break_minutes: 30, overtime_enabled: true)
      # 540 worked - 30 break = 510 effective; 510 - 480 - 0 grace = 30
      expect(described_class.overtime_minutes(shift, 540, overtime_grace_minutes: 0, rule_profile: profile)).to eq(30)
    end

    it "returns 0 when there is no shift" do
      expect(described_class.overtime_minutes(nil, 600, overtime_grace_minutes: 0)).to eq(0)
    end
  end

  describe ".derive_status" do
    # 09:00–17:00 fixed shift; build per-example so penalty rules can vary.
    def fixed_shift(penalty_rules: [])
      build(:shift, :fixed_time,
            start_time: Time.zone.parse("09:00"),
            end_time:   Time.zone.parse("17:00"),
            penalty_rules: penalty_rules)
    end

    context "no penalty rules (grace-only fallback)" do
      let(:shift) { fixed_shift }

      it "is late when any minute past grace" do
        expect(described_class.derive_status(shift: shift, late_minutes: 1, early_leave_minutes: 0)).to eq("late")
      end

      it "is early_leave when any early minute past grace" do
        expect(described_class.derive_status(shift: shift, late_minutes: 0, early_leave_minutes: 1)).to eq("early_leave")
      end

      it "is late_early_leave when both apply" do
        expect(described_class.derive_status(shift: shift, late_minutes: 15, early_leave_minutes: 30)).to eq("late_early_leave")
      end

      it "is present when nothing flags" do
        expect(described_class.derive_status(shift: shift, late_minutes: 0, early_leave_minutes: 0)).to eq("present")
      end
    end

    context "penalty-gated (first early-leave rule at 30 min)" do
      let(:shift) do
        fixed_shift(penalty_rules: [
          build(:penalty_rule, rule_type: "early_leave", threshold_minutes: 30, deduction_type: "fixed_amount", deduction_value: 10)
        ])
      end

      it "stays present when 10 min early (below the 30-min threshold)" do
        expect(described_class.derive_status(shift: shift, late_minutes: 0, early_leave_minutes: 10)).to eq("present")
      end

      it "becomes early_leave once the 30-min threshold is reached" do
        expect(described_class.derive_status(shift: shift, late_minutes: 0, early_leave_minutes: 30)).to eq("early_leave")
      end
    end

    context "overtime and priority" do
      let(:shift) { fixed_shift }

      it "is overtime when only overtime present" do
        expect(described_class.derive_status(shift: shift, late_minutes: 0, early_leave_minutes: 0, overtime_minutes: 45)).to eq("overtime")
      end

      it "late wins over overtime" do
        expect(described_class.derive_status(shift: shift, late_minutes: 20, early_leave_minutes: 0, overtime_minutes: 45)).to eq("late")
      end

      it "early_leave wins over overtime" do
        expect(described_class.derive_status(shift: shift, late_minutes: 0, early_leave_minutes: 20, overtime_minutes: 45)).to eq("early_leave")
      end
    end

    context "open record (not completed)" do
      let(:shift) { fixed_shift }

      it "is late when late-flagged" do
        expect(described_class.derive_status(shift: shift, late_minutes: 10, early_leave_minutes: 0, completed: false)).to eq("late")
      end

      it "is incomplete when not late-flagged" do
        expect(described_class.derive_status(shift: shift, late_minutes: 0, early_leave_minutes: 0, completed: false)).to eq("incomplete")
      end
    end
  end
end
