require "rails_helper"

# POST /api/v1/attendance/punch for a floating employee (no home branch): any
# active device of the business is accepted, the log keeps the device's branch
# and the attendance record keeps no branch.
RSpec.describe "API v1 — floating employee punch", type: :request do
  let(:business) { create(:business) }
  let(:branch_a) { create(:branch, business: business) }
  let(:branch_b) { create(:branch, business: business) }
  let(:employee) { create(:user, business: business, employee_code: "F-1", allow_biometric_attendance: true) }

  # Mid-afternoon, so both punches fall on the same work date whenever the suite runs.
  around { |example| travel_to(Time.utc(2026, 11, 2, 12)) { example.run } }

  before { create(:shift_assignment, :floating, user: employee, shift: create(:shift, :hour_based, business: business)) }

  def punch(device, timestamp)
    post "/api/v1/attendance/punch", params: { employee_id: "F-1", timestamp: timestamp.iso8601 },
                                     headers: { "Authorization" => "Bearer #{device.token}" }, as: :json
  end

  it "accepts punches at two branches' devices into one record with no branch" do
    punch(create(:biometric_device, business: business, branch: branch_a), 3.hours.ago)
    expect_legacy_success
    punch(create(:biometric_device, business: business, branch: branch_b), 1.minute.ago)
    expect_legacy_success

    logs = BiometricPunchLog.where(employee: employee).order(:punched_at)
    expect(logs.map(&:branch_id)).to eq([ branch_a.id, branch_b.id ])
    expect(AttendanceRecord.where(user: employee).pluck(:branch_id)).to eq([ nil ])
  end

  it "still refuses a device of another business" do
    other = create(:business)

    punch(create(:biometric_device, business: other, branch: create(:branch, business: other)), 1.minute.ago)

    expect_legacy_error(:not_found)
    expect(AttendanceRecord.where(user: employee)).to be_empty
  end
end
