require "rails_helper"

RSpec.describe Attendance::CheckInService do
  let(:business)    { create(:business, timezone: "UTC") }
  let(:branch)      { create(:branch, business: business) }
  let(:user)        { create(:user, business: business) }
  let(:shift)       { create(:shift, :fixed_time, business: business) }

  before do
    create(:shift_assignment, user: user, branch: branch, shift: shift,
           effective_from: 1.month.ago.to_date)
    create(:user_branch, user: user, branch: branch)
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

  describe "shift not found" do
    it "fails when there is no active shift assignment for today" do
      # Close the existing assignment
      ShiftAssignment.where(user: user).update_all(effective_to: 1.day.ago.to_date)
      result = call
      expect(result).not_to be_success
      expect(result.error).to eq("No active shift found for today")
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
      create(:user_branch, user: geo_user, branch: geo_branch)
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
