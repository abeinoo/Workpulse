require "rails_helper"

RSpec.describe Attendance::TimestampParser do
  # Helpers — no DB needed.
  def business_in(tz_name)
    instance_double("Business", timezone: tz_name, timezone_object: ActiveSupport::TimeZone[tz_name])
  end

  # Reliable non-DST timezones
  let(:riyadh)  { business_in("Riyadh") }      # UTC+3 always
  let(:kolkata) { business_in("Kolkata") }      # UTC+5:30 always
  let(:utc_biz) { business_in("UTC") }
  let(:ny)      { business_in("Eastern Time (US & Canada)") } # Has DST
  # Cairo in winter = UTC+2; in summer = UTC+3 (EEST). Use explicit winter date.
  let(:cairo)   { business_in("Cairo") }

  # ── Mobile / fallback ─────────────────────────────────────────────────────

  describe "mobile source" do
    it "parses an ISO8601 UTC string" do
      result = described_class.parse("2026-05-24T06:15:00Z", source: :mobile, business: riyadh)
      expect(result.utc.strftime("%H:%M")).to eq("06:15")
    end

    it "falls back to business TZ for bare datetime" do
      # Riyadh UTC+3: 09:15 → 06:15 UTC
      result = described_class.parse("2026-05-24 09:15:00", source: :mobile, business: riyadh)
      expect(result.utc.strftime("%H:%M")).to eq("06:15")
    end
  end

  # ── Biometric device source ────────────────────────────────────────────────

  describe "biometric_device source" do
    context "Riyadh (UTC+3, no DST)" do
      it "parses bare datetime as business local time" do
        # Device sends local clock time without TZ tag
        result = described_class.parse("2026-05-24 09:15:00", source: :biometric_device, business: riyadh)
        expect(result.utc.strftime("%H:%M")).to eq("06:15")
      end

      it "round-trips: UTC stored → displayed back as original local time" do
        result = described_class.parse("2026-05-24 09:15:00", source: :biometric_device, business: riyadh)
        display = result.in_time_zone(riyadh.timezone_object).strftime("%H:%M")
        expect(display).to eq("09:15")
      end

      it "respects ISO8601 +03:00 offset — no double conversion" do
        result = described_class.parse("2026-05-24T09:15:00+03:00", source: :biometric_device, business: riyadh)
        expect(result.utc.strftime("%H:%M")).to eq("06:15")
        expect(result.in_time_zone(riyadh.timezone_object).strftime("%H:%M")).to eq("09:15")
      end

      it "respects ISO8601 Z (UTC) suffix" do
        result = described_class.parse("2026-05-24T06:15:00Z", source: :biometric_device, business: riyadh)
        expect(result.utc.strftime("%H:%M")).to eq("06:15")
      end
    end

    context "Kolkata (UTC+5:30, no DST) — non-integer offset" do
      it "parses bare datetime as local Kolkata time" do
        # 09:15 Kolkata = 09:15 - 5:30 = 03:45 UTC
        result = described_class.parse("2026-05-24 09:15:00", source: :biometric_device, business: kolkata)
        expect(result.utc.strftime("%H:%M")).to eq("03:45")
      end

      it "respects explicit +05:30 offset" do
        result = described_class.parse("2026-05-24T09:15:00+05:30", source: :biometric_device, business: kolkata)
        expect(result.utc.strftime("%H:%M")).to eq("03:45")
      end
    end

    context "UTC business" do
      it "treats bare datetime as UTC" do
        result = described_class.parse("2026-05-24 09:15:00", source: :biometric_device, business: utc_biz)
        expect(result.utc.strftime("%H:%M")).to eq("09:15")
      end
    end

    context "Cairo — winter date (UTC+2, no DST in January)" do
      it "correctly shifts by 2 hours in winter" do
        result = described_class.parse("2026-01-15 09:15:00", source: :biometric_device, business: cairo)
        expect(result.utc.strftime("%H:%M")).to eq("07:15")
      end
    end

    describe "no double-conversion guard" do
      it "a device-tagged Riyadh time displays identically after round-trip" do
        # Before the fix: Time.zone.parse("09:15:00+03:00") treated it as UTC,
        # stored 09:15 UTC, displayed as 12:15 in Riyadh (wrong by +3).
        # With the fix: stored 06:15 UTC, displayed 09:15 in Riyadh (correct).
        result  = described_class.parse("2026-05-24T09:15:00+03:00", source: :biometric_device, business: riyadh)
        display = result.in_time_zone(riyadh.timezone_object).strftime("%H:%M")
        expect(display).to eq("09:15"), "Expected 09:15 in Riyadh — double-conversion regression"
      end
    end

    describe "nil / blank / invalid inputs" do
      it "returns nil for empty string"   do
        expect(described_class.parse("",  source: :biometric_device, business: riyadh)).to be_nil
      end

      it "returns nil for nil"            do
        expect(described_class.parse(nil, source: :biometric_device, business: riyadh)).to be_nil
      end

      it "returns nil for unparseable"    do
        expect(described_class.parse("not-a-date", source: :biometric_device, business: riyadh)).to be_nil
      end
    end
  end

  # ── Import source ──────────────────────────────────────────────────────────

  describe "import source" do
    it "treats bare datetime as business local time (Riyadh)" do
      result = described_class.parse("2026-05-24 09:15:00", source: :import, business: riyadh)
      expect(result.utc.strftime("%H:%M")).to eq("06:15")
    end

    it "treats bare datetime as business local time (Kolkata)" do
      result = described_class.parse("2026-05-24 09:15:00", source: :import, business: kolkata)
      expect(result.utc.strftime("%H:%M")).to eq("03:45")
    end

    it "respects explicit offset when provided" do
      result = described_class.parse("2026-05-24T09:15:00+03:00", source: :import, business: riyadh)
      expect(result.utc.strftime("%H:%M")).to eq("06:15")
    end
  end

  # ── Admin manual source ────────────────────────────────────────────────────

  describe "admin_manual source" do
    it "parses bare time as business local (Riyadh)" do
      result = described_class.parse("2026-05-24 14:30:00", source: :admin_manual, business: riyadh)
      expect(result.utc.strftime("%H:%M")).to eq("11:30")
    end

    it "respects explicit ISO8601 offset" do
      result = described_class.parse("2026-05-24T14:30:00+03:00", source: :admin_manual, business: riyadh)
      expect(result.utc.strftime("%H:%M")).to eq("11:30")
    end
  end

  # ── DST-safe: New York ─────────────────────────────────────────────────────

  describe "DST handling — New York" do
    it "summer (EDT, UTC-4): 09:00 local → 13:00 UTC" do
      result = described_class.parse("2026-07-15 09:00:00", source: :biometric_device, business: ny)
      expect(result.utc.strftime("%H:%M")).to eq("13:00")
    end

    it "winter (EST, UTC-5): 09:00 local → 14:00 UTC" do
      result = described_class.parse("2026-01-15 09:00:00", source: :biometric_device, business: ny)
      expect(result.utc.strftime("%H:%M")).to eq("14:00")
    end
  end

  # ── explicit_offset? detection edge cases ─────────────────────────────────

  describe "offset detection" do
    it "treats no-offset string as business TZ" do
      result = described_class.parse("2026-05-24 09:15", source: :biometric_device, business: riyadh)
      expect(result.utc.strftime("%H:%M")).to eq("06:15")
    end

    it "treats +0000 offset as UTC" do
      result = described_class.parse("2026-05-24T09:15:00+0000", source: :biometric_device, business: riyadh)
      expect(result.utc.strftime("%H:%M")).to eq("09:15")
    end

    it "treats Z suffix as UTC" do
      result = described_class.parse("2026-05-24T09:15:00Z", source: :biometric_device, business: riyadh)
      expect(result.utc.strftime("%H:%M")).to eq("09:15")
    end

    it "treats lowercase z suffix as UTC" do
      result = described_class.parse("2026-05-24T09:15:00z", source: :biometric_device, business: riyadh)
      expect(result.utc.strftime("%H:%M")).to eq("09:15")
    end
  end
end
