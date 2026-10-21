require "rails_helper"

# F2 — the Attendance & Payroll implementation of Shifts::AttendanceUsage,
# exercised through the contract.
RSpec.describe Attendance::ShiftAssignmentUsage do
  let(:contract)   { Shifts::AttendanceUsage }
  let(:business)   { create(:business, timezone: "UTC") }
  let(:branch)     { create(:branch, business: business) }
  let(:assignment) do
    create(:shift_assignment, user: create(:user, business: business), branch: branch,
                              shift: create(:shift, :fixed_time, business: business),
                              effective_from: 1.month.from_now.to_date)
  end

  def attend!(deleted: false)
    AttendanceRecord.create!(
      user: assignment.user, branch: branch, shift_assignment: assignment, work_date: Date.current, date: Date.current,
      check_in_at: Time.zone.parse("#{Date.current} 09:00:00"), check_in_source: "biometric_device",
      late_minutes: 0, early_leave_minutes: 0, status: "incomplete", deleted_at: (deleted ? Time.current : nil)
    )
  end

  def selected(id)
    sql = contract.recorded_against_sql(assignment_column: "shift_assignments.id")
    ShiftAssignment.select("shift_assignments.id", Arel.sql("#{sql} AS used")).find(id).used
  end

  it "answers false without attendance and true with (a soft-deleted record counts), in SQL as well" do
    expect(contract.recorded_against?(assignment_id: assignment.id)).to be(false)
    expect(selected(assignment.id)).to be(false)
    attend!(deleted: true)
    expect(contract.recorded_against?(assignment_id: assignment.id)).to be(true)
    expect(selected(assignment.id)).to be(true)
  end

  it "keeps the index's exact EXISTS expression" do
    expect(contract.recorded_against_sql(assignment_column: "shift_assignments.id"))
      .to eq("EXISTS(SELECT 1 FROM attendance_records ar WHERE ar.shift_assignment_id = shift_assignments.id LIMIT 1)")
  end

  it "never calls back into Workforce" do
    code = File.read(Rails.root.join("app/services/attendance/shift_assignment_usage.rb")).lines.grep_v(/^\s*#/).join
    expect(code).not_to match(/\bShiftAssignment\b|Shifts::|Scheduling::|\.destroy|\.update/)
  end
end
