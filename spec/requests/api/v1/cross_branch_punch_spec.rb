require "rails_helper"

# POST /api/v1/attendance/punch across branches: the device token decides the
# business (tenant isolation unchanged), the device's branch is the punch's
# actual branch, and the employee's assigned branch need not match it.
RSpec.describe "API v1 — cross-branch biometric punch", type: :request do
  let(:business) { create(:business) }
  let(:branch_a) { create(:branch, business: business) }
  let(:branch_b) { create(:branch, business: business) }
  let(:shift)    { create(:shift, :fixed_time, business: business) }
  let(:device_b) { create(:biometric_device, business: business, branch: branch_b) }
  let(:employee) do
    create(:user, business: business, employee_code: "E-100", allow_biometric_attendance: true)
  end

  before { create(:shift_assignment, user: employee, branch: branch_a, shift: shift) }

  def punch(device, employee_id: "E-100", timestamp: Time.current.iso8601)
    post "/api/v1/attendance/punch", params: { employee_id: employee_id, timestamp: timestamp },
                                     headers: { "Authorization" => "Bearer #{device.token}" }, as: :json
  end

  it "accepts an employee assigned to Branch A at a Branch B device, recording Branch B on the log only" do
    punch(device_b)

    expect_legacy_success
    log = BiometricPunchLog.find_by!(employee: employee)
    expect(log.branch).to eq(branch_b)
    expect(log.biometric_device).to eq(device_b)
    expect(log.attendance_record.branch).to eq(branch_a)
    expect(JSON.parse(log.raw_payload)).to include("employee_id" => "E-100")
  end

  it "does not let a device of another business punch this business's employee" do
    other_business = create(:business)
    foreign_device = create(:biometric_device, business: other_business,
                                               branch: create(:branch, business: other_business))

    punch(foreign_device)

    expect_legacy_error(:not_found, message: I18n.t("api.punch.employee_not_found"))
    expect(BiometricPunchLog.where(employee: employee)).to be_empty
    expect(AttendanceRecord.where(user: employee)).to be_empty
  end

  it "does not let a device of another business punch by numeric user id either" do
    other_business = create(:business)
    foreign_device = create(:biometric_device, business: other_business)

    punch(foreign_device, employee_id: employee.id.to_s)

    expect_legacy_error(:not_found)
    expect(AttendanceRecord.where(user: employee)).to be_empty
  end

  it "still refuses an inactive device, whatever its branch" do
    device_b.update_column(:active, false)

    punch(device_b)

    expect_legacy_error(:unauthorized)
    expect(BiometricPunchLog.where(employee: employee)).to be_empty
  end

  it "logs but does not apply a punch from a device whose branch is inactive" do
    device_b
    branch_b.update_column(:active, false)

    punch(device_b)

    expect_legacy_error(:unprocessable_content, message: I18n.t("api.punch.branch_inactive"))
    expect(BiometricPunchLog.find_by!(employee: employee)).to have_attributes(
      action: "rejected_branch_inactive", branch_id: branch_b.id
    )
    expect(AttendanceRecord.where(user: employee)).to be_empty
  end

  it "records the device's branch on a refused stale-timestamp punch" do
    punch(device_b, timestamp: 8.days.ago.iso8601)

    expect(response).to have_http_status(:unprocessable_content)
    expect(BiometricPunchLog.find_by!(employee: employee)).to have_attributes(
      action: "rejected_stale_timestamp", branch_id: branch_b.id
    )
  end
end
