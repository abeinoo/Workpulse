require "rails_helper"

RSpec.describe Attendance::CheckInService do
  let(:business)    { create(:business, timezone: "UTC") }
  let(:branch)      { create(:branch, business: business) }
  let(:user)        { create(:user, business: business) }
  let(:shift)       { create(:shift, :fixed_time, business: business) }

  before do
    create(:shift_assignment, user: user, branch: branch, shift: shift,
           effective_from: 1.month.ago.to_date)
  end

  def call(latitude: nil, longitude: nil)
    described_class.call(user: user, branch: branch,
                         latitude: latitude, longitude: longitude)
  end

  describe "successful check-in" do
    it "returns success" do
      expect(call).to be_success
    end

    it "creates an AttendanceRecord" do
      expect { call }.to change(AttendanceRecord, :count).by(1)
    end

    it "sets the date to today" do
      expect(call.record.date).to eq(Date.current)
    end

    it "sets work_date to today" do
      expect(call.record.work_date).to eq(Date.current)
    end

    it "sets status to :incomplete when checked in on time" do
      travel_to(Time.zone.parse("09:00")) { expect(call.record.status).to eq("incomplete") }
    end

    it "sets status to :late when checked in after shift start" do
      travel_to(Time.zone.parse("10:00")) { expect(call.record.status).to eq("late") }
    end

    it "records late_minutes correctly" do
      travel_to(Time.zone.parse("10:30")) do
        result = call
        expect(result.record.late_minutes).to eq(90)
      end
    end
  end

  describe "business-day boundary (configurable start hour)" do
    # Business day starts at 06:00. A check-in at 02:00 belongs to the PREVIOUS
    # business day, not a new calendar day. UTC business so wall-clock == work_date math.
    let(:business) { create(:business, timezone: "UTC", business_day_start_hour: 6) }

    it "assigns a 02:00 check-in to the previous business day" do
      travel_to Time.utc(2026, 5, 24, 2, 0, 0) do
        result = call
        expect(result).to be_success
        expect(result.record.work_date).to eq(Date.new(2026, 5, 23))
        expect(result.record.date).to eq(Date.new(2026, 5, 23))
      end
    end

    it "assigns a 05:59 check-in to the previous business day" do
      travel_to Time.utc(2026, 5, 24, 5, 59, 0) do
        expect(call.record.work_date).to eq(Date.new(2026, 5, 23))
      end
    end

    it "rolls over to the new business day at 06:00" do
      travel_to Time.utc(2026, 5, 24, 6, 0, 0) do
        expect(call.record.work_date).to eq(Date.new(2026, 5, 24))
      end
    end

    it "blocks a second check-in after midnight as 'already checked in' for the same business day" do
      travel_to(Time.utc(2026, 5, 23, 20, 0, 0)) { call }    # evening check-in → work_date May 23
      travel_to(Time.utc(2026, 5, 24, 2, 0, 0)) do            # 02:00 next morning → still May 23
        expect(call.error).to eq("Already checked in today")
      end
    end
  end

  describe "double check-in prevention" do
    it "returns an error when the user has already checked in today" do
      call
      second = call
      expect(second).not_to be_success
      expect(second.error).to eq("Already checked in today")
    end

    it "does not create a second AttendanceRecord" do
      call
      expect { call }.not_to change(AttendanceRecord, :count)
    end
  end

  describe "branch assignment check" do
    it "fails when the user is not assigned to the branch" do
      unassigned_branch = create(:branch, business: business)
      result = described_class.call(user: user, branch: unassigned_branch)
      expect(result).not_to be_success
      expect(result.error).to eq("You are not assigned to this branch")
    end
  end

  describe "no active assignment" do
    it "fails the branch-assignment check when the assignment is closed" do
      # Branch membership is shift-driven: closing the only active assignment also
      # removes branch membership, so the branch-assignment guard fires first.
      ShiftAssignment.where(user: user).update_all(effective_to: 1.day.ago.to_date)
      result = call
      expect(result).not_to be_success
      expect(result.error).to eq("You are not assigned to this branch")
    end
  end

  describe "geolocation enforcement" do
    let(:geo_user) { create(:user, business: business) }
    let(:geo_branch) do
      create(:branch, :with_geolocation, business: business,
             latitude: 24.7136, longitude: 46.6753, radius_meters: 100)
    end

    before do
      create(:shift_assignment, user: geo_user, branch: geo_branch, shift: shift,
             effective_from: 1.month.ago.to_date)
    end

    it "succeeds when coordinates are inside the allowed radius" do
      result = described_class.call(user: geo_user, branch: geo_branch,
                                    latitude: 24.7136, longitude: 46.6753)
      expect(result).to be_success
    end

    it "fails when coordinates are outside the allowed radius" do
      result = described_class.call(user: geo_user, branch: geo_branch,
                                    latitude: 25.0000, longitude: 47.0000)
      expect(result).not_to be_success
      expect(result.error).to eq("You are outside the allowed check-in area")
    end

    it "fails when coordinates are missing" do
      result = described_class.call(user: geo_user, branch: geo_branch)
      expect(result).not_to be_success
    end
  end
end
