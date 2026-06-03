require "rails_helper"

RSpec.describe Attendance::ManualEntryService do
  let(:business)  { create(:business, timezone: "UTC") }
  let(:branch)    { create(:branch, business: business) }
  let(:shift)     { create(:shift, :fixed_time, business: business) }
  let(:creator)   { create(:user, :owner, business: business) }
  let(:employee)  { create(:user, business: business) }
  let(:work_date) { Date.current - 1.day }

  let!(:assignment) do
    create(:shift_assignment,
           user:           employee,
           branch:         branch,
           shift:          shift,
           effective_from: 1.year.ago.to_date)
  end

  def call(**overrides)
    described_class.call(
      employee:   employee,
      created_by: creator,
      work_date:  work_date,
      check_in:   "09:00",
      **overrides
    )
  end

  it "creates an attendance record with the chosen work_date" do
    result = call
    expect(result).to be_success
    record = result.record
    expect(record).to be_persisted
    expect(record.work_date).to eq(work_date)
    expect(record.date).to eq(work_date)
  end

  it "records created_by / updated_by and admin_manual source" do
    record = call.record
    expect(record.created_by).to eq(creator)
    expect(record.updated_by).to eq(creator)
    expect(record.check_in_source).to eq("admin_manual")
  end

  it "links the employee's active shift assignment and branch" do
    record = call.record
    expect(record.shift_assignment).to eq(assignment)
    expect(record.branch).to eq(branch)
  end

  it "writes an audit log and a manual_entry adjustment with the note" do
    expect {
      call(notes: "Forgot to punch, confirmed with manager")
    }.to change(AuditLog, :count).by(1)

    record = AttendanceRecord.order(:created_at).last
    adj = record.attendance_adjustments.find_by(field_name: "manual_entry")
    expect(adj.reason).to eq("Forgot to punch, confirmed with manager")
  end

  it "computes worked_minutes when a check-out is given" do
    record = call(check_out: "17:00").record
    expect(record.worked_minutes).to eq(480)
    expect(record.check_out_source).to eq("admin_manual")
  end

  it "rolls an overnight check-out to the next calendar day" do
    record = call(check_in: "20:00", check_out: "04:00").record
    out = record.check_out_at.in_time_zone(business.timezone_object)
    expect(out.to_date).to eq(work_date + 1.day)
    expect(record.worked_minutes).to eq(480) # 20:00 → 04:00 = 8h
  end

  it "fails when the employee already has a record for that date" do
    create(:attendance_record, user: employee, branch: branch,
           shift_assignment: assignment,
           date: work_date, work_date: work_date,
           check_in_at: Time.utc(work_date.year, work_date.month, work_date.day, 9))
    result = call
    expect(result).not_to be_success
    expect(result.error).to eq(I18n.t("attendance.manual.errors.duplicate"))
  end

  it "requires a check-in time" do
    result = call(check_in: "")
    expect(result).not_to be_success
    expect(result.error).to eq(I18n.t("attendance.manual.errors.check_in_required"))
  end
end
