require "rails_helper"

# Cross-branch biometric attendance: an employee may punch at any device of
# their business, whatever branch their shift assignment is at. The punch log
# keeps the device's branch (the actual branch of the punch, copied when it is
# received); the attendance record keeps the assignment's branch and is
# aggregated exactly as before — one per employee and work date.
RSpec.describe Attendance::PunchService, "cross-branch punches" do
  around { |ex| travel_to(Time.zone.local(2026, 5, 20, 12, 0, 0)) { ex.run } }

  let(:business)  { create(:business, timezone: "Asia/Riyadh", business_day_start_hour: 6) }
  let(:branch_a)  { create(:branch, business: business, name: "Branch A") }
  let(:branch_b)  { create(:branch, business: business, name: "Branch B") }
  let(:branch_c)  { create(:branch, business: business, name: "Branch C") }
  let(:device_a)  { create(:biometric_device, business: business, branch: branch_a) }
  let(:device_b)  { create(:biometric_device, business: business, branch: branch_b) }
  let(:shift)     { create(:shift, :fixed_time, business: business) }
  let(:employee)  { create(:user, :employee, business: business, allow_biometric_attendance: true) }
  let!(:assignment) do
    create(:shift_assignment, user: employee, shift: shift, branch: branch_a, effective_from: Date.new(2026, 5, 1))
  end

  def punch(time_str, device:)
    described_class.call(employee: employee, punched_at: Time.zone.parse(time_str), business: business, device: device)
  end

  def logs = BiometricPunchLog.where(employee: employee).order(:punched_at)

  it "accepts a punch at another branch's device: the log keeps the device's branch, the record the assignment's" do
    result = punch("2026-05-17 09:00:00 +03:00", device: device_b)

    expect(result).to be_success
    expect(result.action).to eq("check_in")
    expect(result.log.branch).to eq(branch_b)
    expect(result.log.biometric_device).to eq(device_b)
    expect(result.record.branch).to eq(branch_a)
    expect(result.record.shift_assignment).to eq(assignment)
  end

  it "aggregates a check-in at Branch A and a check-out at Branch B into one complete record" do
    punch("2026-05-17 09:00:00 +03:00", device: device_a)
    result = punch("2026-05-17 17:00:00 +03:00", device: device_b)

    expect(result.action).to eq("check_out")
    record = AttendanceRecord.find_by!(user: employee, work_date: Date.new(2026, 5, 17))
    expect(AttendanceRecord.where(user: employee).count).to eq(1)
    expect(record.check_in_at).to eq(Time.zone.parse("2026-05-17 09:00:00 +03:00"))
    expect(record.check_out_at).to eq(Time.zone.parse("2026-05-17 17:00:00 +03:00"))
    expect(record.early_leave_minutes).to eq(0)
    expect(record.late_minutes).to eq(0)
    expect(record.branch).to eq(branch_a)
    expect(logs.map(&:branch)).to eq([ branch_a, branch_b ])
  end

  it "keeps every punch of a day spread over several branches, deriving the earliest and latest" do
    punch("2026-05-17 09:00:00 +03:00", device: device_a)
    punch("2026-05-17 12:00:00 +03:00", device: device_b)
    punch("2026-05-17 13:00:00 +03:00", device: device_a)
    punch("2026-05-17 17:00:00 +03:00", device: device_b)

    expect(AttendanceRecord.where(user: employee).count).to eq(1)
    record = AttendanceRecord.find_by!(user: employee)
    expect(record.check_in_at).to eq(Time.zone.parse("2026-05-17 09:00:00 +03:00"))
    expect(record.check_out_at).to eq(Time.zone.parse("2026-05-17 17:00:00 +03:00"))
    expect(record.status).not_to eq("incomplete")
    expect(logs.map(&:branch)).to eq([ branch_a, branch_b, branch_a, branch_b ])
    expect(logs.map(&:attendance_record_id).uniq).to eq([ record.id ])
  end

  it "derives the same record whatever branch's punch arrives first" do
    punch("2026-05-17 17:00:00 +03:00", device: device_b)
    punch("2026-05-17 09:00:00 +03:00", device: device_a)

    record = AttendanceRecord.find_by!(user: employee)
    expect(record.check_in_at).to eq(Time.zone.parse("2026-05-17 09:00:00 +03:00"))
    expect(record.check_out_at).to eq(Time.zone.parse("2026-05-17 17:00:00 +03:00"))
  end

  it "leaves the employee's branch membership unchanged" do
    expect { punch("2026-05-17 09:00:00 +03:00", device: device_b) }
      .not_to change { ShiftAssignment.where(user: employee).pluck(:id, :branch_id, :assignment_kind) }
    expect(employee.reload.business).to eq(business)
  end

  it "still requires an active shift assignment, at any branch" do
    assignment.update_column(:effective_to, Date.new(2026, 5, 10))

    result = punch("2026-05-17 09:00:00 +03:00", device: device_b)

    expect(result.action).to eq("rejected_no_assignment")
    expect(result.log.branch).to eq(branch_b)
    expect(AttendanceRecord.where(user: employee)).to be_empty
  end

  describe "a device with no branch (not yet configured)" do
    let(:unassigned) { create(:biometric_device, business: business, branch: nil) }

    it "keeps accepting punches, logged with no branch" do
      result = punch("2026-05-17 09:00:00 +03:00", device: unassigned)

      expect(result).to be_success
      expect(result.log.branch_id).to be_nil
      expect(result.record.branch).to eq(branch_a)
    end
  end

  describe "a device whose branch has been deactivated" do
    before do
      device_b
      branch_b.update_column(:active, false)
    end

    it "logs the punch with its branch and applies nothing" do
      result = punch("2026-05-17 09:00:00 +03:00", device: device_b)

      expect(result).not_to be_success
      expect(result.action).to eq("rejected_branch_inactive")
      expect(result.error).to eq(I18n.t("api.punch.branch_inactive"))
      expect(result.log.branch).to eq(branch_b)
      expect(result.log.work_date).to eq(Date.new(2026, 5, 17))
      expect(AttendanceRecord.where(user: employee)).to be_empty
    end

    it "does not make a punch at an active branch moments later look like a duplicate" do
      punch("2026-05-17 09:00:00 +03:00", device: device_b)
      result = punch("2026-05-17 09:00:30 +03:00", device: device_a)

      expect(result.action).to eq("check_in")
    end

    it "is not punch evidence for the aggregation" do
      punch("2026-05-17 09:00:00 +03:00", device: device_b)
      punch("2026-05-17 10:00:00 +03:00", device: device_a)

      expect(AttendanceRecord.find_by!(user: employee).check_in_at).to eq(Time.zone.parse("2026-05-17 10:00:00 +03:00"))
    end
  end

  describe "moving a device to another branch" do
    it "attributes only later punches to the new branch; earlier logs keep theirs" do
      first = punch("2026-05-17 09:00:00 +03:00", device: device_b).log

      device_b.update!(branch: branch_c)
      second = punch("2026-05-17 17:00:00 +03:00", device: device_b.reload).log

      expect(first.reload.branch).to eq(branch_b)
      expect(second.branch).to eq(branch_c)
    end

    it "never rewrites a logged branch" do
      log = punch("2026-05-17 09:00:00 +03:00", device: device_b).log

      expect { log.update(branch: branch_c) }.to raise_error(ActiveRecord::ReadonlyAttributeError)
      expect(log.reload.branch).to eq(branch_b)
    end

    it "keeps the logged branch when the device is deleted" do
      log = punch("2026-05-17 09:00:00 +03:00", device: device_b).log

      device_b.destroy!

      expect(log.reload.biometric_device_id).to be_nil
      expect(log.branch).to eq(branch_b)
    end
  end
end
