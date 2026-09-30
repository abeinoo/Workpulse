require "rails_helper"

# Characterization: POST /api/v1/attendance/punch — the device-token realm
# (Api::V1::BiometricBaseController < ActionController::API, no Devise session).
RSpec.describe "API v1 characterization — biometric punch", type: :request do
  let(:business) { create(:business) }
  let(:branch)   { create(:branch, business: business) }
  let(:shift)    { create(:shift, :fixed_time, business: business) }
  let(:device)   { create(:biometric_device, business: business) }
  let(:employee) do
    create(:user, business: business, employee_code: "E-100", allow_biometric_attendance: true)
  end

  before { create(:shift_assignment, user: employee, branch: branch, shift: shift) }

  def punch(params, headers: { "Authorization" => "Bearer #{device.token}" })
    post "/api/v1/attendance/punch", params: params, headers: headers, as: :json
  end

  it "returns 401 in the legacy envelope without a device token" do
    punch({ employee_id: "E-100", timestamp: Time.current.iso8601 }, headers: {})
    expect_legacy_error(:unauthorized, message: "Invalid or missing device token")
  end

  it "returns 401 for an inactive device" do
    device.update_column(:active, false)
    punch({ employee_id: "E-100", timestamp: Time.current.iso8601 })
    expect_legacy_error(:unauthorized)
  end

  it "accepts the X-Device-Token header as an alternative" do
    punch({ employee_id: "E-100", timestamp: Time.current.iso8601 }, headers: { "X-Device-Token" => device.token })
    expect(response).to have_http_status(:ok)
  end

  it "ignores a signed-in web session (device realm only)" do
    sign_in employee
    punch({ employee_id: "E-100", timestamp: Time.current.iso8601 }, headers: {})
    expect_legacy_error(:unauthorized)
  end

  it "returns the punch payload on success" do
    punch({ employee_id: "E-100", timestamp: Time.current.iso8601 })
    expect_legacy_success
    expect(api_data.keys).to match_array(%w[action work_date punched_at attendance_record])
  end

  it "returns 404 for an employee_id that is not in the device's business" do
    create(:user, employee_code: "E-900")
    punch({ employee_id: "E-900", timestamp: Time.current.iso8601 })
    expect_legacy_error(:not_found, message: I18n.t("api.punch.employee_not_found"))
  end

  it "returns 422 for an invalid timestamp" do
    punch({ employee_id: "E-100", timestamp: "nope" })
    expect_legacy_error(:unprocessable_content, message: I18n.t("api.punch.invalid_timestamp"))
  end

  it "returns 422 for a timestamp outside the 24-hour window" do
    punch({ employee_id: "E-100", timestamp: 3.days.ago.iso8601 })
    expect_legacy_error(:unprocessable_content, message: I18n.t("api.punch.stale_timestamp"))
  end

  it "returns 422 when the employee may not use biometric attendance" do
    employee.update_column(:allow_biometric_attendance, false)
    punch({ employee_id: "E-100", timestamp: Time.current.iso8601 })
    expect_legacy_error(:unprocessable_content, message: I18n.t("api.punch.biometric_attendance_not_allowed"))
  end
end
