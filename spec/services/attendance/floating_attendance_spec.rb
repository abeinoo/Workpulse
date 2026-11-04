require "rails_helper"

# A floating employee (no home branch) punching at devices of several branches
# in one work day: one record per work date with a NULL branch, check-in from
# the earliest punch and check-out from the latest, every punch's actual branch
# kept on its log, and late / early-leave computed in the business's time zone
# exactly as live punching and recalculation both derive them.
RSpec.describe "Floating employee attendance" do
  # A non-UTC zone, so a calculation that skipped the time zone would be off by hours.
  let(:business) { create(:business, timezone: "Asia/Riyadh") }
  let(:zone)     { business.timezone_object }
  let(:branch_a) { create(:branch, business: business) }
  let(:branch_b) { create(:branch, business: business) }
  let(:device_a) { create(:biometric_device, business: business, branch: branch_a) }
  let(:device_b) { create(:biometric_device, business: business, branch: branch_b) }
  let(:employee) { create(:user, business: business, allow_biometric_attendance: true) }
  let(:day)      { Date.new(2026, 11, 2) }
  let(:fixed)    do
    create(:shift, :fixed_time, business: business,
                                start_time: Time.zone.parse("09:00"), end_time: Time.zone.parse("17:00"))
  end

  def at(hour, min = 0) = zone.local(day.year, day.month, day.day, hour, min)

  def punch(device, time)
    Attendance::PunchService.call(employee: employee, punched_at: time, business: business, device: device)
  end

  def record = AttendanceRecord.find_by!(user: employee, work_date: day)

  context "with a fixed-time shift" do
    let!(:assignment) do
      create(:shift_assignment, :floating, user: employee, shift: fixed, effective_from: day - 30)
    end

    it "accepts punches at any branch's device: the floating assignment satisfies the assignment requirement" do
      expect(punch(device_a, at(9, 30))).to be_success
      expect(punch(device_b, at(10, 45))).to be_success
    end

    it "aggregates a day across branches into one record with a NULL branch" do
      punch(device_a, at(9, 30))
      punch(device_b, at(12))
      punch(device_b, at(16))

      expect(AttendanceRecord.where(user: employee).count).to eq(1)
      expect(record).to have_attributes(
        branch_id:           nil,
        shift_assignment_id: assignment.id,
        check_in_at:         at(9, 30),
        check_out_at:        at(16),
        late_minutes:        30,
        early_leave_minutes: 60,
        worked_minutes:      390
      )
    end

    it "keeps every punch, the intermediate one included, with the branch of its device" do
      punch(device_a, at(9, 30))
      punch(device_b, at(12))
      punch(device_b, at(16))

      logs = BiometricPunchLog.where(employee: employee).order(:punched_at)
      expect(logs.map(&:branch_id)).to eq([ branch_a.id, branch_b.id, branch_b.id ])
      expect(logs.map(&:attendance_record_id).uniq).to eq([ record.id ])
    end

    it "derives the same record whatever order the punches arrive in" do
      punch(device_b, at(16))
      punch(device_b, at(12))
      punch(device_a, at(9, 30))

      expect(record).to have_attributes(check_in_at: at(9, 30), check_out_at: at(16),
                                        late_minutes: 30, early_leave_minutes: 60, branch_id: nil)
    end

    it "computes no lateness for an on-time arrival" do
      punch(device_a, at(9))
      punch(device_b, at(17))

      expect(record).to have_attributes(late_minutes: 0, early_leave_minutes: 0, status: "present")
    end

    it "produces the values live punching produced when recalculated" do
      punch(device_a, at(9, 30))
      punch(device_b, at(16))
      live = record.slice(:late_minutes, :early_leave_minutes, :worked_minutes, :overtime_minutes, :status)

      reloaded = AttendanceRecord.includes(:user, shift_assignment: :shift).find(record.id)
      expect(Attendance::RecordRecomputer.recompute!(reloaded)).to be(false)
      expect(reloaded.slice(*live.keys)).to eq(live)
    end
  end

  context "with an hour-based shift" do
    let(:hours) { create(:shift, :hour_based, business: business, required_hours: 8) }

    before { create(:shift_assignment, :floating, user: employee, shift: hours, effective_from: day - 30) }

    it "measures early leave against the required hours, and recalculation agrees" do
      punch(device_a, at(9))
      punch(device_b, at(15))

      expect(record).to have_attributes(branch_id: nil, late_minutes: 0, worked_minutes: 360, early_leave_minutes: 120)

      reloaded = AttendanceRecord.find(record.id)
      expect(Attendance::RecordRecomputer.recompute!(reloaded)).to be(false)
    end
  end

  it "still refuses an employee with no assignment at all" do
    result = punch(device_a, at(9))

    expect(result.action).to eq("rejected_no_assignment")
  end

  it "still refuses a device whose branch is inactive" do
    create(:shift_assignment, :floating, user: employee, shift: fixed, effective_from: day - 30)
    device_b
    branch_b.update_column(:active, false)

    expect(punch(device_b, at(9)).action).to eq("rejected_branch_inactive")
    expect(AttendanceRecord.where(user: employee)).to be_empty
  end
end
