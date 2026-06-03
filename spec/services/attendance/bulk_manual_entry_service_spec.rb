require "rails_helper"

RSpec.describe Attendance::BulkManualEntryService do
  let(:business) { create(:business, timezone: "Asia/Riyadh") }
  let(:branch)   { create(:branch, business: business) }
  let(:shift)    { create(:shift, :fixed_time, business: business) }
  let(:creator)  { create(:user, :owner, business: business) }
  let!(:emp1)    { create(:user, business: business, employee_code: "EMP001") }
  let!(:emp2)    { create(:user, business: business, employee_code: "EMP002") }

  before do
    [ emp1, emp2 ].each do |u|
      create(:shift_assignment, user: u, branch: branch, shift: shift,
             effective_from: Date.new(2026, 1, 1))
    end
  end

  def run(rows, allowed: [ emp1.id, emp2.id ])
    described_class.new(
      rows: rows, business: business, created_by: creator, allowed_user_ids: allowed
    ).call
  end

  let(:good_rows) do
    [
      { user_id: emp1.id, work_date: "2026-06-01", check_in: "09:00", check_out: "17:00", notes: "a" },
      { user_id: emp2.id, work_date: "2026-06-01", check_in: "20:00", check_out: "04:00", notes: "overnight" }
    ]
  end

  it "creates all records in one batch and reports the count" do
    expect { @result = run(good_rows) }.to change(AttendanceRecord, :count).by(2)
    expect(@result).to be_success
    expect(@result.count).to eq(2)
  end

  it "sets created_by and writes audit + manual_entry adjustment per record" do
    expect { run(good_rows) }.to change(AuditLog, :count).by(2)
    rec = AttendanceRecord.find_by(user: emp1, work_date: Date.new(2026, 6, 1))
    expect(rec.created_by).to eq(creator)
    expect(rec.attendance_adjustments.where(field_name: "manual_entry")).to be_present
  end

  it "rolls an overnight check-out to the next day" do
    run(good_rows)
    rec = AttendanceRecord.find_by(user: emp2, work_date: Date.new(2026, 6, 1))
    out = rec.check_out_at.in_time_zone(business.timezone_object)
    expect(out.to_date).to eq(Date.new(2026, 6, 2))
    expect(rec.worked_minutes).to eq(480)
  end

  it "is all-or-nothing: one bad row saves nothing" do
    rows = good_rows + [ { user_id: emp1.id, work_date: "bad-date", check_in: "09:00" } ]
    expect { @result = run(rows) }.not_to change(AttendanceRecord, :count)
    expect(@result).to be_failed
    expect(@result.row_errors).not_to be_empty
  end

  it "rejects rows whose employee is outside the allowed scope" do
    expect { @result = run(good_rows, allowed: [ emp1.id ]) }.not_to change(AttendanceRecord, :count)
    expect(@result).to be_failed
  end

  it "rejects an in-batch duplicate (same employee + date twice)" do
    rows = [
      { user_id: emp1.id, work_date: "2026-06-01", check_in: "09:00" },
      { user_id: emp1.id, work_date: "2026-06-01", check_in: "10:00" }
    ]
    expect { @result = run(rows) }.not_to change(AttendanceRecord, :count)
    expect(@result.row_errors.flat_map(&:messages).join).to match(/more than once|Duplicate/i)
  end

  it "rejects a duplicate against an existing DB record" do
    create(:attendance_record, user: emp1, branch: branch,
           shift_assignment: emp1.shift_assignments.first,
           date: Date.new(2026, 6, 1), work_date: Date.new(2026, 6, 1))
    rows = [ { user_id: emp1.id, work_date: "2026-06-01", check_in: "09:00" } ]
    expect { @result = run(rows) }.not_to change(AttendanceRecord, :count)
    expect(@result).to be_failed
  end

  it "regenerates only draft payroll for affected months" do
    allow(Payroll::DraftRegenerator).to receive(:call)
    run(good_rows)
    expect(Payroll::DraftRegenerator).to have_received(:call).with(
      hash_including(business: business, months: [ [ 2026, 6 ] ])
    )
  end

  context "when the target month's payroll is locked" do
    before { create(:payroll_period, :finalized, business: business, period_year: 2026, period_month: 6) }

    it "still saves the records and counts them as locked" do
      expect { @result = run(good_rows) }.to change(AttendanceRecord, :count).by(2)
      expect(@result).to be_success
      expect(@result.locked_count).to eq(2)
    end
  end
end
