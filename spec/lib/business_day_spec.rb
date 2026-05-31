require "rails_helper"

RSpec.describe BusinessDay do
  # context: a lightweight double that satisfies BusinessDay.work_date_for's interface.
  def ctx(timezone:, start_hour: 0)
    tz = ActiveSupport::TimeZone[timezone]
    double("context", timezone_object: tz, business_day_start_hour: start_hour)
  end

  describe ".work_date_for" do
    context "UTC business (no offset)" do
      let(:utc_ctx) { ctx(timezone: "UTC") }

      it "returns the UTC calendar date for a midday timestamp" do
        ts = Time.utc(2026, 5, 24, 12, 0, 0)
        expect(described_class.work_date_for(ts, context: utc_ctx)).to eq(Date.new(2026, 5, 24))
      end

      it "returns the same UTC date at 23:59" do
        ts = Time.utc(2026, 5, 24, 23, 59, 0)
        expect(described_class.work_date_for(ts, context: utc_ctx)).to eq(Date.new(2026, 5, 24))
      end
    end

    # Africa/Cairo is EET (UTC+2) in winter, EEST (UTC+3) in summer.
    # Use January dates so the UTC+2 offset is stable and predictable.
    context "Africa/Cairo business (UTC+2 in winter, January dates)" do
      let(:cairo_ctx) { ctx(timezone: "Africa/Cairo") }

      it "returns the Cairo date at 07:00 UTC (= 09:00 Cairo EET)" do
        ts = Time.utc(2026, 1, 24, 7, 0, 0)
        expect(described_class.work_date_for(ts, context: cairo_ctx)).to eq(Date.new(2026, 1, 24))
      end

      it "advances to the next Cairo date at 22:30 UTC (= 00:30 Cairo EET next day)" do
        ts = Time.utc(2026, 1, 24, 22, 30, 0)
        expect(described_class.work_date_for(ts, context: cairo_ctx)).to eq(Date.new(2026, 1, 25))
      end

      it "assigns 22:00 UTC (= 00:00 Cairo EET, boundary with start_hour=0) to the next date" do
        ts = Time.utc(2026, 1, 24, 22, 0, 0)
        # 00:00 Cairo, start_hour=0 → hour(0) >= 0 → Cairo date = Jan 25
        expect(described_class.work_date_for(ts, context: cairo_ctx)).to eq(Date.new(2026, 1, 25))
      end
    end

    context "Asia/Riyadh business (UTC+3)" do
      let(:riyadh_ctx) { ctx(timezone: "Asia/Riyadh") }

      it "assigns 21:30 UTC (= 00:30 Riyadh next day) to the next Riyadh date" do
        ts = Time.utc(2026, 5, 24, 21, 30, 0)
        expect(described_class.work_date_for(ts, context: riyadh_ctx)).to eq(Date.new(2026, 5, 25))
      end

      it "keeps 20:59 UTC (= 23:59 Riyadh) on the same Riyadh date" do
        ts = Time.utc(2026, 5, 24, 20, 59, 0)
        expect(described_class.work_date_for(ts, context: riyadh_ctx)).to eq(Date.new(2026, 5, 24))
      end
    end

    context "business_day_start_hour = 6 (shift starts at 6 AM)" do
      # A business where "today" only starts at 6 AM. A punch at 5:50 AM belongs to yesterday.
      let(:early_ctx) { ctx(timezone: "UTC", start_hour: 6) }

      it "assigns 05:50 UTC to the previous calendar day" do
        ts = Time.utc(2026, 5, 24, 5, 50, 0)
        expect(described_class.work_date_for(ts, context: early_ctx)).to eq(Date.new(2026, 5, 23))
      end

      it "assigns 06:00 UTC to the current calendar day" do
        ts = Time.utc(2026, 5, 24, 6, 0, 0)
        expect(described_class.work_date_for(ts, context: early_ctx)).to eq(Date.new(2026, 5, 24))
      end
    end
  end

  # .for_timestamp is an explicit alias of .work_date_for for readability at
  # call sites that resolve a specific punch's business day.
  describe ".for_timestamp" do
    let(:early_ctx) { ctx(timezone: "UTC", start_hour: 6) }

    it "delegates to work_date_for" do
      ts = Time.utc(2026, 5, 24, 2, 0, 0)
      expect(described_class.for_timestamp(ts, context: early_ctx))
        .to eq(described_class.work_date_for(ts, context: early_ctx))
    end

    it "assigns a 02:00 punch to the previous business day when start_hour = 6" do
      ts = Time.utc(2026, 5, 24, 2, 0, 0)
      expect(described_class.for_timestamp(ts, context: early_ctx)).to eq(Date.new(2026, 5, 23))
    end
  end

  # .current resolves "today" for "now" — the helper that replaced the scattered
  # Date.current / Time.current.in_time_zone(tz).to_date calls across the app.
  describe ".current" do
    context "with business_day_start_hour = 6 (UTC business)" do
      let(:early_ctx) { ctx(timezone: "UTC", start_hour: 6) }

      it "returns the PREVIOUS day for a 02:00 'now'" do
        travel_to Time.utc(2026, 5, 24, 2, 0, 0) do
          expect(described_class.current(context: early_ctx)).to eq(Date.new(2026, 5, 23))
        end
      end

      it "returns the PREVIOUS day at 05:59 (just before the start hour)" do
        travel_to Time.utc(2026, 5, 24, 5, 59, 0) do
          expect(described_class.current(context: early_ctx)).to eq(Date.new(2026, 5, 23))
        end
      end

      it "rolls over to the CURRENT day exactly at 06:00 (the start hour)" do
        travel_to Time.utc(2026, 5, 24, 6, 0, 0) do
          expect(described_class.current(context: early_ctx)).to eq(Date.new(2026, 5, 24))
        end
      end
    end

    context "overnight shift in Asia/Riyadh (UTC+3) with start_hour = 6" do
      let(:riyadh_ctx) { ctx(timezone: "Asia/Riyadh", start_hour: 6) }

      it "keeps a 02:00 Riyadh 'now' on the previous business day" do
        # 23:00 UTC on May 23 = 02:00 Riyadh on May 24; before the 06:00 start → May 23
        travel_to Time.utc(2026, 5, 23, 23, 0, 0) do
          expect(described_class.current(context: riyadh_ctx)).to eq(Date.new(2026, 5, 23))
        end
      end
    end

    it "accepts an explicit now: argument" do
      ctx_obj = ctx(timezone: "UTC", start_hour: 6)
      expect(described_class.current(context: ctx_obj, now: Time.utc(2026, 5, 24, 3, 0, 0)))
        .to eq(Date.new(2026, 5, 23))
    end
  end
end
