require "rails_helper"

RSpec.describe Attendance::CheckOutService do
  let(:business) { create(:business, timezone: "UTC") }
  let(:branch)   { create(:branch, business: business) }
  let(:user)     { create(:user, business: business) }
  let(:shift)    { create(:shift, :fixed_time, business: business) }
  # Use yesterday at 09:00 so check_in_at is always before today's travel_to targets
  # (15:00 and 17:00) regardless of what time of day the test suite runs.
  let!(:open_record) do
    create(:attendance_record, user: user, branch: branch, shift: shift,
           check_in_at: 1.day.ago.change(hour: 9, min: 0, sec: 0),
           work_date:   Date.yesterday, date: Date.yesterday)
  end

  def call(latitude: nil, longitude: nil)
    described_class.call(user: user, branch: branch,
                         latitude: latitude, longitude: longitude)
  end

  describe "successful check-out" do
    it "returns success" do
      expect(call).to be_success
    end

    it "sets check_out_at on the record" do
      call
      expect(open_record.reload.check_out_at).to be_present
    end

    it "calculates worked_minutes" do
      travel_to(open_record.check_in_at + 8.hours) do
        call
        expect(open_record.reload.worked_minutes).to eq(480)
      end
    end

    it "sets status to :present when no early leave" do
      # Exactly the scheduled 8h (09:00–17:00) → no early leave, no overtime.
      travel_to(open_record.check_in_at + 8.hours) do
        call
        expect(open_record.reload.status).to eq("present")
      end
    end

    it "sets status to :overtime when working beyond the shift + grace" do
      travel_to(open_record.check_in_at + 10.hours) do
        call
        expect(open_record.reload.status).to eq("overtime")
        expect(open_record.reload.overtime_minutes).to eq(120)
      end
    end

    it "sets status to :early_leave when checking out before shift end" do
      travel_to(Time.zone.parse("15:00")) do
        call
        expect(open_record.reload.status).to eq("early_leave")
      end
    end

    it "records early_leave_minutes" do
      travel_to(Time.zone.parse("15:00")) do
        call
        expect(open_record.reload.early_leave_minutes).to eq(120)
      end
    end
  end

  describe "missing check-in" do
    it "fails when there is no open check-in" do
      open_record.update!(status: :present, check_out_at: Time.current)
      result = call
      expect(result).not_to be_success
      expect(result.error).to eq("No active check-in found")
    end
  end

  describe "overnight checkout (next calendar day)" do
    let(:overnight_shift) { create(:shift, :overnight, business: business) }
    let(:overnight_user)  { create(:user, business: business) }
    let(:work_day)        { Date.current }
    let!(:overnight_record) do
      create(:attendance_record,
             user:        overnight_user,
             branch:      branch,
             shift:       overnight_shift,
             work_date:   work_day,
             date:        work_day,
             check_in_at: 3.hours.ago.change(sec: 0),
             status:      :incomplete)
    end

    it "finds and checks out an open record even after midnight" do
      result = described_class.call(user: overnight_user, branch: branch)
      expect(result).to be_success
      expect(result.record.check_out_at).to be_present
    end

    it "preserves the original work_date after checkout" do
      described_class.call(user: overnight_user, branch: branch)
      expect(overnight_record.reload.work_date).to eq(work_day)
    end
  end

  describe "geolocation enforcement" do
    let(:geo_user) { create(:user, business: business) }
    let(:geo_branch) do
      create(:branch, :with_geolocation, business: business,
             latitude: 24.7136, longitude: 46.6753, radius_meters: 100)
    end
    let!(:geo_record) do
      create(:attendance_record, user: geo_user, branch: geo_branch, shift: shift)
    end

    it "fails when coordinates are outside the allowed radius" do
      result = described_class.call(user: geo_user, branch: geo_branch,
                                    latitude: 25.0000, longitude: 47.0000)
      expect(result).not_to be_success
      expect(result.error).to eq("You are outside the allowed check-out area")
    end

    it "succeeds when inside the allowed radius" do
      result = described_class.call(user: geo_user, branch: geo_branch,
                                    latitude: 24.7136, longitude: 46.6753)
      expect(result).to be_success
    end
  end
end
