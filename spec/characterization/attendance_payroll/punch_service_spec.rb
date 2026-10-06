require "rails_helper"

# Characterization (Milestone 2 Pilot 1, M1) — CURRENT Attendance::PunchService
# rules not pinned by spec/services/attendance/punch_service_spec.rb: which logs
# count toward the spam window, duplicate/equal punches, check-in refinement
# lateness, rejection log shape, business isolation, and one known defect.
RSpec.describe "Characterization: Attendance::PunchService" do
  around { |example| travel_to(Time.zone.parse("2026-05-20 09:00:00 UTC")) { example.run } }

  let(:business) { create(:business, timezone: "Asia/Riyadh", business_day_start_hour: 6) }
  let(:branch)   { create(:branch, business: business) }
  let(:shift)    { create(:shift, :fixed_time, business: business) } # 09:00–17:00
  let(:device)   { create(:biometric_device, business: business) }
  let(:employee) { create(:user, business: business, allow_biometric_attendance: true) }

  before do
    create(:shift_assignment, user: employee, branch: branch, shift: shift, effective_from: Date.new(2026, 5, 1))
  end

  def riyadh(time) = Time.zone.parse("2026-05-20 #{time} +03:00")

  def punch(time, **options)
    Attendance::PunchService.call(employee: employee, punched_at: riyadh(time), business: business, device: device, **options)
  end

  def prior_log(action:, at:, source: "biometric", business_for_log: business)
    create(:biometric_punch_log, business: business_for_log, employee: employee, action: action, source: source,
                                 punched_at: riyadh(at), work_date: Date.new(2026, 5, 20))
  end

  describe "spam window (60 seconds around the punch)" do
    it "counts any earlier log of the employee in the business — other device, mobile source, rejected_spam, rejected_not_allowed" do
      %w[check_in rejected_spam rejected_not_allowed].each_with_index do |action, index|
        prior_log(action: action, at: "08:00:#{10 + index}", source: index.odd? ? "mobile" : "biometric")
      end

      result = punch("08:00:30")

      expect(result).to have_attributes(success?: true, action: "rejected_spam", record: nil)
      expect(AttendanceRecord.where(user: employee)).to be_empty
    end

    it "ignores rejected_no_assignment and error logs" do
      prior_log(action: "rejected_no_assignment", at: "08:00:00")
      prior_log(action: "error",                  at: "08:00:10")

      expect(punch("08:00:30").action).to eq("check_in")
    end

    it "is symmetric: a later-timestamped existing log also makes the punch spam" do
      prior_log(action: "check_in", at: "08:01:00")
      expect(punch("08:00:30").action).to eq("rejected_spam")
    end

    it "ignores the same employee's logs recorded under another business" do
      prior_log(action: "check_in", at: "08:00:10", business_for_log: create(:business))
      expect(punch("08:00:30").action).to eq("check_in")
    end

    it "logs every spam rejection (a duplicate punch adds a log, never a record change)" do
      punch("08:00:00")
      record = AttendanceRecord.find_by!(user: employee)

      expect { punch("08:00:00") }.to change(BiometricPunchLog, :count).by(1)
      expect(BiometricPunchLog.last).to have_attributes(action: "rejected_spam", attendance_record_id: nil)
      expect(record.reload.check_in_at).to eq(riyadh("08:00:00"))
    end
  end

  describe "check-in refinement and check-out" do
    # Note: late_minutes drops to 0 but the status stays "late" (it is only
    # replaced when the new punch is late too); check-out re-derives the status.
    it "recalculates lateness when an earlier punch replaces a late check-in" do
      late = punch("09:30:00")
      expect(late.record).to have_attributes(status: "late", late_minutes: 30)

      earlier = punch("08:55:00")

      expect(earlier.action).to eq("check_in_updated")
      expect(earlier.record.reload).to have_attributes(check_in_at: riyadh("08:55:00"), late_minutes: 0, status: "late")
    end

    it "treats a punch equal to the current check-out as spam (success, nothing changes)" do
      punch("08:00:00")
      punch("17:00:00")

      result = punch("17:00:00")

      expect(result).to have_attributes(success?: true, action: "rejected_spam")
      expect(AttendanceRecord.find_by!(user: employee).check_out_at).to eq(riyadh("17:00:00"))
    end
  end

  describe "rejection log shape" do
    it "logs rejected_not_allowed with no work_date and no record, before any assignment lookup" do
      employee.update_column(:allow_biometric_attendance, false)

      result = punch("08:00:00", ip_address: "10.0.0.5", raw_payload: { "employee_id" => "E-1" })

      expect(result).to have_attributes(success?: false, action: "rejected_not_allowed")
      expect(result.log).to have_attributes(work_date: nil, attendance_record_id: nil, biometric_device_id: device.id,
                                            ip_address: "10.0.0.5", raw_payload: '{"employee_id":"E-1"}')
    end

    it "logs without a device when called without one" do
      result = Attendance::PunchService.call(employee: employee, punched_at: riyadh("08:00:00"), business: business)
      expect(result.log.biometric_device_id).to be_nil
      expect(result.log.source).to eq("biometric")
    end
  end

  # KNOWN DEFECT AP-D3 (pinned, not fixed): a punch on a work date whose
  # attendance record was soft-deleted (deleted_at) updates that deleted record
  # and reports success — the attendance stays invisible (AttendanceRecord.active
  # excludes it). The unique (user_id, work_date) index prevents a new record.
  it "updates a soft-deleted record for the same work date and reports success (AP-D3)" do
    first = punch("08:00:00").record
    first.update_columns(deleted_at: Time.current)

    result = punch("17:00:00")

    expect(result).to have_attributes(success?: true, action: "check_out")
    expect(result.record.id).to eq(first.id)
    expect(first.reload.deleted_at).to be_present
    expect(AttendanceRecord.active.where(user: employee)).to be_empty
  end
end
