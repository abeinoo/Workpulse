require "rails_helper"

RSpec.describe Attendance::StatusBackfill do
  let(:business) { create(:business, timezone: "UTC", overtime_grace_minutes: 0) }
  let(:branch)   { create(:branch, business: business) }
  let(:user)     { create(:user, business: business) }
  let(:shift)    { create(:shift, :fixed_time, business: business) } # 09:00–17:00, 480 min

  def record_with(check_out_hour:, late: 0, early: 0, worked:, status: "present")
    create(:attendance_record, :checked_out,
           user: user, branch: branch, shift: shift,
           check_in_at:  Time.current.change(hour: 9, min: 0, sec: 0),
           check_out_at: Time.current.change(hour: check_out_hour, min: 0, sec: 0),
           late_minutes: late, early_leave_minutes: early, worked_minutes: worked,
           status: status)
  end

  it "reclassifies a long day as overtime and stores overtime_minutes" do
    rec = record_with(check_out_hour: 19, worked: 600, status: "present") # 120 over

    result = described_class.call(dry_run: false)

    expect(rec.reload.status).to eq("overtime")
    expect(rec.overtime_minutes).to eq(120)
    expect(result.to_overtime).to eq(1)
  end

  it "reclassifies a both-penalty day as late_early_leave" do
    rec = record_with(check_out_hour: 16, late: 30, early: 60, worked: 420, status: "late")

    described_class.call(dry_run: false)

    expect(rec.reload.status).to eq("late_early_leave")
  end

  it "NEVER changes late_minutes / early_leave_minutes / worked_minutes" do
    rec = record_with(check_out_hour: 19, late: 5, early: 7, worked: 600, status: "present")
    before = rec.slice(:late_minutes, :early_leave_minutes, :worked_minutes)

    described_class.call(dry_run: false)

    after = rec.reload.slice(:late_minutes, :early_leave_minutes, :worked_minutes)
    expect(after).to eq(before)
  end

  it "leaves absent records untouched" do
    rec = create(:attendance_record, :checked_out, user: user, branch: branch, shift: shift,
                 status: "absent", worked_minutes: 600,
                 check_in_at: Time.current.change(hour: 9), check_out_at: Time.current.change(hour: 19))

    described_class.call(dry_run: false)

    expect(rec.reload.status).to eq("absent")
  end

  it "dry_run reports counts without writing" do
    rec = record_with(check_out_hour: 19, worked: 600, status: "present")

    result = described_class.call(dry_run: true)

    expect(result.to_overtime).to eq(1)
    expect(rec.reload.status).to eq("present")     # unchanged
    expect(rec.overtime_minutes).to eq(0)
  end
end
