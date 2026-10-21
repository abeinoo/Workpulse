require "rails_helper"

# Characterization (Milestone 2 Pilot 1, M1) — CURRENT POST /api/v1/attendance/punch
# behaviour beyond spec/requests/api/v1/characterization/biometric_punch_spec.rb:
# employee lookup, timestamp edge cases, duplicate punches, check-out payload,
# rejection logging and what each punch records.
RSpec.describe "Characterization: biometric punch API", type: :request do
  around { |example| travel_to(Time.zone.parse("2026-05-20 07:00:00 UTC")) { example.run } } # 10:00 in Riyadh

  let(:business) { create(:business, timezone: "Asia/Riyadh", business_day_start_hour: 6) }
  let(:branch)   { create(:branch, business: business) }
  let(:shift)    { create(:shift, :fixed_time, business: business) }
  let(:device)   { create(:biometric_device, business: business) }
  let(:employee) { create(:user, business: business, employee_code: "E-100", allow_biometric_attendance: true) }

  before do
    create(:shift_assignment, user: employee, branch: branch, shift: shift, effective_from: Date.new(2026, 5, 1))
  end

  def punch(params)
    post "/api/v1/attendance/punch", params: params, headers: { "Authorization" => "Bearer #{device.token}" }, as: :json
  end

  def json = JSON.parse(response.body)

  describe "employee lookup" do
    it "matches employee_code first, then the user id" do
      by_code = create(:user, business: business, employee_code: employee.id.to_s, allow_biometric_attendance: true)
      create(:shift_assignment, user: by_code, branch: branch, shift: shift, effective_from: Date.new(2026, 5, 1))

      punch(employee_id: employee.id.to_s, timestamp: Time.current.iso8601)

      expect(response).to have_http_status(:ok)
      expect(BiometricPunchLog.last.employee).to eq(by_code)
    end

    it "accepts a plain user id when no employee_code matches" do
      punch(employee_id: employee.id, timestamp: Time.current.iso8601)

      expect(response).to have_http_status(:ok)
      expect(BiometricPunchLog.last.employee).to eq(employee)
    end

    it "returns 404 for an inactive employee or a blank employee_id, without logging" do
      employee.update_column(:active, false)

      expect { punch(employee_id: "E-100", timestamp: Time.current.iso8601) }.not_to change(BiometricPunchLog, :count)
      expect(response).to have_http_status(:not_found)

      expect { punch(employee_id: "", timestamp: Time.current.iso8601) }.not_to change(BiometricPunchLog, :count)
      expect(response).to have_http_status(:not_found)
    end

    it "checks the employee before the timestamp (unknown employee + bad timestamp is 404)" do
      punch(employee_id: "NOPE", timestamp: "nonsense")
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "timestamps" do
    it "returns 422 invalid_timestamp when the timestamp is missing, without logging" do
      expect { punch(employee_id: "E-100") }.not_to change(BiometricPunchLog, :count)
      expect(response).to have_http_status(:unprocessable_content)
      expect(json["message"]).to eq(I18n.t("api.punch.invalid_timestamp"))
    end

    it "returns 422 stale_timestamp for a timestamp 25 hours ahead (beyond the 5-minute future tolerance)" do
      punch(employee_id: "E-100", timestamp: 25.hours.from_now.iso8601)
      expect(response).to have_http_status(:unprocessable_content)
      expect(json["message"]).to eq(I18n.t("api.punch.stale_timestamp"))
    end

    it "accepts a timestamp 23 hours old (inside the 7-day window)" do
      punch(employee_id: "E-100", timestamp: 23.hours.ago.iso8601)
      expect(response).to have_http_status(:ok)
    end

    it "reads a timestamp without an offset as business-local time and answers in the business offset" do
      punch(employee_id: "E-100", timestamp: "2026-05-20 09:30:00")

      expect(response).to have_http_status(:ok)
      expect(json.dig("data", "punched_at")).to eq("2026-05-20T09:30:00+03:00")
      expect(json.dig("data", "work_date")).to eq("2026-05-20")
      expect(BiometricPunchLog.last.punched_at).to eq(Time.utc(2026, 5, 20, 6, 30))
    end
  end

  describe "punch flow" do
    it "answers a first punch with check_in and the attendance record" do
      punch(employee_id: "E-100", timestamp: "2026-05-20T09:00:00+03:00")

      expect(json["data"]).to include("action" => "check_in", "work_date" => "2026-05-20")
      expect(json.dig("data", "attendance_record")).to include(
        "work_date" => "2026-05-20", "check_in_at" => "2026-05-20T09:00:00+03:00", "check_out_at" => nil
      )
    end

    it "answers a later punch with check_out on the same record" do
      punch(employee_id: "E-100", timestamp: "2026-05-20T06:00:00+03:00")
      first_id = json.dig("data", "attendance_record", "id")

      punch(employee_id: "E-100", timestamp: "2026-05-20T09:45:00+03:00")

      expect(json.dig("data", "action")).to eq("check_out")
      expect(json.dig("data", "attendance_record")).to include(
        "id" => first_id, "check_out_at" => "2026-05-20T09:45:00+03:00"
      )
    end

    it "answers an identical duplicate punch with 200 rejected_spam and no attendance change" do
      punch(employee_id: "E-100", timestamp: "2026-05-20T09:00:00+03:00")
      record = AttendanceRecord.find_by!(user: employee)

      expect { punch(employee_id: "E-100", timestamp: "2026-05-20T09:00:00+03:00") }
        .to change(BiometricPunchLog, :count).by(1)

      expect(response).to have_http_status(:ok)
      expect(json["data"]).to include("action" => "rejected_spam", "attendance_record" => nil)
      expect(record.reload.check_in_at).to eq(Time.utc(2026, 5, 20, 6, 0))
      expect(AttendanceRecord.where(user: employee).count).to eq(1)
    end

    it "returns 422 no_shift_assignment and logs rejected_no_assignment for an unassigned employee" do
      unassigned = create(:user, business: business, employee_code: "E-200", allow_biometric_attendance: true)

      punch(employee_id: "E-200", timestamp: Time.current.iso8601)

      expect(response).to have_http_status(:unprocessable_content)
      expect(json["message"]).to eq(I18n.t("api.punch.no_shift_assignment"))
      expect(BiometricPunchLog.last).to have_attributes(employee_id: unassigned.id, action: "rejected_no_assignment",
                                                        attendance_record_id: nil)
    end

    it "records device, source, IP address and the raw payload on the log" do
      punch(employee_id: "E-100", timestamp: "2026-05-20T09:00:00+03:00")

      log = BiometricPunchLog.last
      expect(log).to have_attributes(business_id: business.id, biometric_device_id: device.id, source: "biometric",
                                     action: "check_in", ip_address: "127.0.0.1",
                                     attendance_record_id: AttendanceRecord.find_by!(user: employee).id)
      expect(JSON.parse(log.raw_payload)).to eq("employee_id" => "E-100", "timestamp" => "2026-05-20T09:00:00+03:00")
      expect(log.received_at).to eq(Time.current)
    end
  end
end
