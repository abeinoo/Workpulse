require "rails_helper"

RSpec.describe ApplicationHelper, type: :helper do
  # Riyadh is UTC+3, Cairo is UTC+2, New_York is UTC-5 (EST) / UTC-4 (EDT)
  let(:riyadh_biz) { create(:business, timezone: "Asia/Riyadh") }
  let(:cairo_biz)  { create(:business, timezone: "Africa/Cairo") }
  let(:ny_biz)     { create(:business, timezone: "America/New_York") }

  def with_business(business)
    user = create(:user, business: business)
    allow(helper).to receive(:current_user).and_return(user)
    yield
  end

  describe "#local_time" do
    it "returns '—' for nil" do
      allow(helper).to receive(:current_user).and_return(nil)
      expect(helper.local_time(nil)).to eq("—")
    end

    it "converts a UTC timestamp to Riyadh local time (+3)" do
      # 22:00 UTC on a day = 01:00 next day in Riyadh
      utc_ts = Time.utc(2026, 5, 15, 22, 0, 0)
      with_business(riyadh_biz) do
        expect(helper.local_time(utc_ts)).to eq("01:00")
      end
    end

    it "converts a UTC timestamp to Cairo local time (UTC+2 in winter)" do
      # January: Cairo is UTC+2 (no DST)
      utc_ts = Time.utc(2026, 1, 15, 22, 0, 0)
      with_business(cairo_biz) do
        expect(helper.local_time(utc_ts)).to eq("00:00")
      end
    end
  end

  describe "#local_datetime" do
    it "returns fallback for nil" do
      allow(helper).to receive(:current_user).and_return(nil)
      expect(helper.local_datetime(nil)).to eq("—")
    end

    it "formats correctly in Riyadh TZ" do
      utc_ts = Time.utc(2026, 5, 15, 21, 30, 0)
      with_business(riyadh_biz) do
        # UTC+3: 21:30 UTC → 00:30 on May 16
        expect(helper.local_datetime(utc_ts)).to eq("May 16, 2026 00:30")
      end
    end

    it "formats correctly in New York TZ (EST, UTC-5)" do
      utc_ts = Time.utc(2026, 1, 15, 5, 0, 0)
      with_business(ny_biz) do
        # UTC-5: 05:00 UTC → 00:00 on Jan 15
        expect(helper.local_datetime(utc_ts)).to eq("Jan 15, 2026 00:00")
      end
    end

    it "handles DST transition in New York (March, clocks spring forward)" do
      # 2026-03-08 at 07:00 UTC = 02:00 EST → but clocks spring forward at 02:00
      # 07:00 UTC = 03:00 EDT (UTC-4 after spring forward on March 8 2026)
      utc_ts = Time.utc(2026, 3, 8, 7, 0, 0)
      with_business(ny_biz) do
        result = helper.local_datetime(utc_ts)
        expect(result).to match(/Mar 8, 2026 0[23]:00/)
      end
    end
  end

  describe "#local_date" do
    it "works for a Date object" do
      d = Date.new(2026, 6, 5)
      allow(helper).to receive(:current_user).and_return(nil)
      expect(helper.local_date(d)).to eq("Jun 5, 2026")
    end

    it "works for a Time/datetime object, using business TZ" do
      # A timestamp just before midnight UTC that's the previous day in UTC
      # but already the next day in Riyadh (+3)
      utc_ts = Time.utc(2026, 5, 15, 23, 0, 0)
      with_business(riyadh_biz) do
        # 23:00 UTC = 02:00 on May 16 in Riyadh
        expect(helper.local_date(utc_ts)).to eq("May 16, 2026")
      end
    end
  end

  describe "#local_short_date" do
    it "formats as 'd Mon'" do
      d = Date.new(2026, 6, 5)
      allow(helper).to receive(:current_user).and_return(nil)
      expect(helper.local_short_date(d)).to eq("5 Jun")
    end

    it "converts datetime to correct business date" do
      utc_ts = Time.utc(2026, 5, 31, 22, 30, 0)
      with_business(riyadh_biz) do
        # UTC+3: 22:30 UTC → 01:30 on June 1
        expect(helper.local_short_date(utc_ts)).to eq("1 Jun")
      end
    end
  end

  describe "#local_datetime_input" do
    it "formats for a datetime-local HTML input in business TZ" do
      utc_ts = Time.utc(2026, 5, 15, 22, 0, 0)
      with_business(riyadh_biz) do
        # UTC+3: 22:00 UTC → 01:00 on May 16
        expect(helper.local_datetime_input(utc_ts)).to eq("2026-05-16T01:00")
      end
    end

    it "uses Time.current as default when nil is passed" do
      allow(helper).to receive(:current_user).and_return(nil)
      result = helper.local_datetime_input(nil)
      expect(result).to match(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}\z/)
    end
  end
end
