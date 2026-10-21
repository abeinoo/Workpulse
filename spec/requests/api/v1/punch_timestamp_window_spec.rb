require "rails_helper"

# SEC-P12-1 — POST /api/v1/attendance/punch timestamp window and locked payroll
# periods (decisions D-T1 … D-T4):
# * a device timestamp may be at most 7 × 24 hours (elapsed) older and at most
#   5 minutes newer than the server's receive time — else 422 stale_timestamp,
#   logged rejected_stale_timestamp, nothing recorded;
# * a punch whose work date falls in a finalized / paid payroll period is refused
#   inside Attendance::PunchService — 422 payroll_locked, logged
#   rejected_payroll_locked, nothing recorded; draft / under-review periods (and
#   no period yet) accept it.
# Time is frozen, so every boundary is exact.
RSpec.describe "API: biometric punch timestamp window and locked payroll (SEC-P12-1)", type: :request do
  around { |example| travel_to(Time.zone.parse("2026-05-20 07:00:00 UTC")) { example.run } } # 10:00 in Riyadh

  let(:business) { create(:business, timezone: "Asia/Riyadh", business_day_start_hour: 6) }
  let(:branch)   { create(:branch, business: business) }
  let(:shift)    { create(:shift, :fixed_time, business: business) }
  let(:device)   { create(:biometric_device, business: business) }
  let(:employee) { create(:user, business: business, employee_code: "E-100", allow_biometric_attendance: true) }

  before do
    create(:shift_assignment, user: employee, branch: branch, shift: shift, effective_from: Date.new(2026, 4, 1))
  end

  def punch(timestamp)
    post "/api/v1/attendance/punch", params: { employee_id: "E-100", timestamp: timestamp },
                                     headers: { "Authorization" => "Bearer #{device.token}" }, as: :json
  end

  def json         = JSON.parse(response.body)
  def last_log     = BiometricPunchLog.order(:id).last
  def attendance   = AttendanceRecord.where(user: employee).order(:work_date).pluck(:work_date, :check_in_at, :check_out_at, :worked_minutes, :late_minutes)
  def stale_error  = I18n.t("api.punch.stale_timestamp")
  def locked_error = I18n.t("api.punch.payroll_locked")

  def expect_stale_refusal
    expect(response).to have_http_status(:unprocessable_content)
    expect(json).to include("success" => false, "message" => stale_error)
    expect(last_log).to have_attributes(action: "rejected_stale_timestamp", attendance_record_id: nil, source: "biometric",
                                        biometric_device_id: device.id, employee_id: employee.id)
    expect(last_log).to be_rejected
    expect(last_log).not_to be_success
  end

  describe "the window (measured against the server's receive time)" do
    it "accepts exactly 7 × 24 hours old" do
      punch((Time.current - 168.hours).iso8601)

      expect(response).to have_http_status(:ok)
      expect(last_log.action).to eq("check_in")
    end

    it "refuses one second older (422, logged as a rejection, no attendance)" do
      expect { punch((Time.current - 168.hours - 1.second).iso8601) }.not_to change(AttendanceRecord, :count)

      expect_stale_refusal
    end

    it "accepts exactly 5 minutes ahead" do
      punch((Time.current + 5.minutes).iso8601)

      expect(response).to have_http_status(:ok)
    end

    it "refuses one second beyond 5 minutes ahead" do
      expect { punch((Time.current + 5.minutes + 1.second).iso8601) }.not_to change(AttendanceRecord, :count)

      expect_stale_refusal
    end

    it "keeps accepting 23 hours old and refusing 25 hours ahead (the earlier examples)" do
      punch(23.hours.ago.iso8601)
      expect(response).to have_http_status(:ok)

      punch(25.hours.from_now.iso8601)
      expect_stale_refusal
    end

    it "measures 168 hours of elapsed time, not seven calendar days" do
      expect(Api::V1::PunchesController::PAST_WINDOW).to eq(168.hours)
      expect(Api::V1::PunchesController::FUTURE_SKEW).to eq(5.minutes)
    end
  end

  describe "parsing and time zones (unchanged parser)" do
    it "applies the window to an explicit offset" do
      punch("2026-05-13T10:00:00+03:00") # exactly 168 h before 2026-05-20 07:00 UTC
      expect(response).to have_http_status(:ok)

      punch("2026-05-13T09:59:59+03:00")
      expect_stale_refusal
    end

    it "reads a timestamp without an offset as business-local time" do
      punch("2026-05-13 10:00:00") # Riyadh = 07:00 UTC, exactly 168 h
      expect(response).to have_http_status(:ok)
      expect(last_log.punched_at).to eq(Time.utc(2026, 5, 13, 7, 0, 0))

      punch("2026-05-13 09:59:59")
      expect_stale_refusal
    end

    it "keeps the business-day work date near midnight (before the 06:00 day start)" do
      punch("2026-05-20 05:30:00") # business-local, before the day starts → the 19th

      expect(response).to have_http_status(:ok)
      expect(last_log.work_date).to eq(Date.new(2026, 5, 19))
    end
  end

  describe "attendance behaviour" do
    it "still acknowledges a duplicate punch with 200 rejected_spam and records it once" do
      punch("2026-05-20 09:00:00")
      expect { punch("2026-05-20 09:00:00") }.not_to change(AttendanceRecord, :count)

      expect(response).to have_http_status(:ok)
      expect(json.dig("data", "action")).to eq("rejected_spam")
    end

    it "keeps out-of-order handling (an earlier valid punch moves check-in earlier)" do
      punch("2026-05-20 09:30:00")
      punch("2026-05-20 08:45:00")

      expect(response).to have_http_status(:ok)
      expect(json.dig("data", "action")).to eq("check_in_updated")
      expect(AttendanceRecord.find_by!(user: employee, work_date: Date.new(2026, 5, 20)).check_in_at)
        .to eq(Time.utc(2026, 5, 20, 5, 45, 0))
    end

    it "cannot change an existing record with a stale or a future punch" do
      punch("2026-05-20 08:00:00")
      punch("2026-05-20 09:30:00")
      before = attendance

      punch("2026-05-12 08:00:00") # eight days old
      expect_stale_refusal
      punch((Time.current + 10.minutes).iso8601) # a later check-out, but beyond the tolerance
      expect_stale_refusal

      expect(attendance).to eq(before)
    end

    it "still updates the device's last_seen_at on a refused request" do
      device.update_column(:last_seen_at, nil)

      punch((Time.current - 8.days).iso8601)

      expect(device.reload.last_seen_at).to eq(Time.current)
    end
  end

  describe "locked payroll periods" do
    def period(status) = create(:payroll_period, business: business, period_year: 2026, period_month: 5).tap { |p| p.update_columns(status: status) }

    %w[finalized paid].each do |status|
      it "refuses a punch whose work date is in a #{status} period (no new record)" do
        period(status)

        expect { punch("2026-05-20 09:00:00") }.not_to change(AttendanceRecord, :count)

        expect(response).to have_http_status(:unprocessable_content)
        expect(json).to include("success" => false, "message" => locked_error)
        expect(last_log).to have_attributes(action: "rejected_payroll_locked", attendance_record_id: nil,
                                            work_date: Date.new(2026, 5, 20))
        expect(last_log).to be_rejected
      end
    end

    it "refuses to update an existing record of a locked period" do
      punch("2026-05-20 08:00:00")
      before = attendance
      period("finalized")

      punch("2026-05-20 09:30:00")

      expect(json["message"]).to eq(locked_error)
      expect(attendance).to eq(before)
    end

    %w[draft under_review].each do |status|
      it "accepts a valid punch in a #{status} period" do
        period(status)

        punch("2026-05-20 09:00:00")

        expect(response).to have_http_status(:ok)
        expect(last_log.action).to eq("check_in")
      end
    end

    it "accepts a valid punch when no payroll period exists for the month yet" do
      punch("2026-05-20 09:00:00")

      expect(response).to have_http_status(:ok)
    end

    it "uses the work date's period: a locked May blocks a late-May punch received in June, not a June punch" do
      travel_back
      travel_to(Time.zone.parse("2026-06-02 07:00:00 UTC")) # both dates inside the 7-day window
      create(:payroll_period, business: business, period_year: 2026, period_month: 5).update_columns(status: "finalized")

      punch("2026-06-02 09:00:00")
      expect(response).to have_http_status(:ok)

      punch("2026-05-31 09:00:00")
      expect(json["message"]).to eq(locked_error)
      expect(last_log).to have_attributes(action: "rejected_payroll_locked", work_date: Date.new(2026, 5, 31))
    end

    it "does not let a locked-period refusal make a later punch look like a duplicate" do
      locked = period("finalized")
      punch("2026-05-20 09:00:00")
      locked.update_columns(status: "under_review")

      punch("2026-05-20 09:00:00")

      expect(json.dig("data", "action")).to eq("check_in")
    end

    it "is enforced inside Attendance::PunchService, whatever the caller" do
      period("paid")

      result = nil
      expect {
        result = Attendance::PunchService.call(employee: employee, punched_at: Time.zone.parse("2026-05-20 06:00 UTC"),
                                               business: business, device: device)
      }.not_to change(AttendanceRecord, :count)

      expect(result).not_to be_success
      expect(result.action).to eq("rejected_payroll_locked")
      expect(result.error).to eq(locked_error)
    end
  end

  describe "audit of refused punches" do
    it "stores the request payload but never the device token" do
      punch((Time.current - 8.days).iso8601)

      expect(last_log.raw_payload).to include("E-100")
      expect(last_log.raw_payload).not_to include(device.token)
    end

    it "keeps refused-punch logs under the SEC-M2-8 punch-log policy" do
      punch((Time.current - 8.days).iso8601)
      log = last_log

      sign_in api_user_with(business, :view_employees)
      get admin_biometric_punch_log_path(log)
      expect(response).to redirect_to(root_path)

      sign_in api_user_with(business, :manage_devices)
      get admin_biometric_punch_log_path(log)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include(I18n.t("admin.biometric_punch_logs.action.rejected_stale_timestamp"))
    end
  end
end
