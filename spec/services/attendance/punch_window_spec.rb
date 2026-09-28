require "rails_helper"

RSpec.describe Attendance::PunchWindow do
  # Riyadh (UTC+3); business day rolls over at midnight unless stated otherwise.
  let(:business)  { create(:business, timezone: "Asia/Riyadh", business_day_start_hour: 0) }
  let(:branch)    { create(:branch, business: business) }
  let(:employee)  { create(:user, business: business) }
  let(:riyadh)    { ActiveSupport::TimeZone["Asia/Riyadh"] }
  let(:work_date) { Date.new(2026, 9, 13) }

  def at(day, hour, min = 0) = riyadh.local(2026, 9, day, hour, min)

  def assign(start_time, end_time)
    create(:shift_assignment, user: employee, branch: branch, effective_from: Date.new(2026, 1, 1),
           shift: create(:shift, :fixed_time, business: business,
                         start_time: Time.zone.parse(start_time), end_time: Time.zone.parse(end_time)))
  end

  subject(:window) { described_class.for(user: employee, work_date: work_date) }

  describe "A. normal same-day shift 09:00 → 17:00" do
    before { assign("09:00", "17:00") }

    it "accepts the scheduled check-in and check-out" do
      expect(window.cover?(at(13, 9))).to be true
      expect(window.cover?(at(13, 17))).to be true
    end

    it "exposes the scheduled span on the work date" do
      expect(window.shift_starts_at).to eq(at(13, 9))
      expect(window.shift_ends_at).to eq(at(13, 17))
    end
  end

  describe "B/C. overnight shift 19:00 → 02:00" do
    before { assign("19:00", "02:00") }

    it "B. accepts the check-in on the work date and the check-out on the next day" do
      expect(window.cover?(at(13, 19))).to be true
      expect(window.cover?(at(14, 2))).to be true
    end

    it "C. accepts a legitimate after-midnight check-out even though the business day rolled over" do
      expect(window.cover?(at(14, 0, 3))).to be true
      expect(window.cover?(at(14, 2, 45))).to be true # within the existing 60-min shift tolerance
    end

    it "ends the scheduled span on the next calendar day" do
      expect(window.shift_ends_at).to eq(at(14, 2))
    end

    it "rejects a punch far past the shift end on the next day" do
      expect(window.cover?(at(14, 5))).to be false
    end
  end

  describe "D. incorrect previous-day attendance" do
    it "flags 12 Sep 03:10 PM for work date 13 Sep (same-day shift)" do
      assign("09:00", "17:00")
      expect(window.cover?(at(12, 15, 10))).to be false
    end

    it "flags 12 Sep 03:10 PM for work date 13 Sep (overnight shift)" do
      assign("19:00", "02:00")
      expect(window.cover?(at(12, 15, 10))).to be false
    end
  end

  describe "E. incorrect far-future punch" do
    it "flags a punch days after the work date" do
      assign("19:00", "02:00")
      expect(window.cover?(at(20, 10))).to be false
      expect(window.cover?(riyadh.local(2027, 9, 13, 20))).to be false
    end
  end

  describe "without a shift assignment" do
    it "does not invent a shift and falls back to the business day only" do
      expect(window.shift).to be_nil
      expect(window.shift_starts_at).to be_nil
      expect(window.cover?(at(13, 23))).to be true
      expect(window.cover?(at(14, 3))).to be false
      expect(window.cover?(at(12, 15, 10))).to be false
    end

    it "honours business_day_start_hour exactly like punch attribution does" do
      business.update!(business_day_start_hour: 6)
      expect(window.cover?(at(14, 3))).to be true   # BusinessDay.work_date_for → 13 Sep
      expect(window.cover?(at(13, 5))).to be false  # still belongs to 12 Sep
    end
  end

  describe "hour-based shift" do
    it "has no fixed clock window and uses the business day" do
      create(:shift_assignment, user: employee, branch: branch, effective_from: Date.new(2026, 1, 1),
             shift: create(:shift, :hour_based, business: business))
      expect(window.shift_starts_at).to be_nil
      expect(window.cover?(at(13, 23, 30))).to be true
      expect(window.cover?(at(12, 23, 30))).to be false
    end
  end

  it "treats a nil time as outside" do
    expect(window.cover?(nil)).to be false
  end
end
