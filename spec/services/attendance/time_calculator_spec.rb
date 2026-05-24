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

  describe ".derive_status" do
    it "returns 'late' when late_minutes > 0" do
      expect(described_class.derive_status(30, 0)).to eq("late")
    end

    it "returns 'early_leave' when early_leave_minutes > 0 and not late" do
      expect(described_class.derive_status(0, 60)).to eq("early_leave")
    end

    it "returns 'present' when no penalties" do
      expect(described_class.derive_status(0, 0)).to eq("present")
    end

    it "returns 'late' when both late and early_leave (late takes precedence)" do
      expect(described_class.derive_status(15, 30)).to eq("late")
    end
  end
end
