require "rails_helper"

RSpec.describe Attendance::ManualRecordsCsvParser do
  let(:business) { create(:business, timezone: "Asia/Riyadh") }
  let!(:emp1)    { create(:user, business: business, employee_code: "EMP001") }
  let!(:emp2)    { create(:user, business: business, employee_code: "EMP002") }

  def parse(csv, allowed: nil)
    described_class.new(csv_data: csv, business: business, allowed_user_ids: allowed).call
  end

  let(:valid_csv) do
    <<~CSV
      employee_code,work_date,check_in,check_out,notes
      EMP001,2026-06-01,09:00,17:00,From sign-in sheet
      EMP002,2026-06-01,20:00,04:00,Overnight
    CSV
  end

  it "parses valid rows with resolved users and normalized values" do
    result = parse(valid_csv)
    expect(result).to be_headers_valid
    expect(result.valid_count).to eq(2)
    row = result.valid_rows.first
    expect(row.user).to eq(emp1)
    expect(row.work_date).to eq(Date.new(2026, 6, 1))
    expect(row.check_in).to eq("09:00")
    expect(row.check_out).to eq("17:00")
    expect(row.notes).to eq("From sign-in sheet")
  end

  it "treats check_out and notes as optional" do
    csv = "employee_code,work_date,check_in\nEMP001,2026-06-02,08:30\n"
    row = parse(csv).valid_rows.first
    expect(row.check_in).to eq("08:30")
    expect(row.check_out).to be_nil
    expect(row.notes).to be_nil
  end

  it "reports a header error when required columns are missing" do
    result = parse("employee_code,check_in\nEMP001,09:00\n")
    expect(result).not_to be_headers_valid
    expect(result.header_error).to include("work_date")
  end

  it "flags an unknown employee_code as invalid" do
    result = parse("employee_code,work_date,check_in\nNOPE,2026-06-01,09:00\n")
    expect(result.invalid_count).to eq(1)
    expect(result.invalid_rows.first.errors.join).to match(/not found/)
  end

  it "does NOT match employees by name — only employee_code" do
    csv = "employee_code,work_date,check_in\n#{emp1.full_name},2026-06-01,09:00\n"
    result = parse(csv)
    expect(result.valid_count).to eq(0)
    expect(result.invalid_rows.first.errors.join).to match(/not found/)
  end

  it "rejects employees outside the allowed scope" do
    result = parse(valid_csv, allowed: [ emp1.id ])
    expect(result.valid_count).to eq(1)
    expect(result.valid_rows.first.user).to eq(emp1)
    expect(result.invalid_rows.first.errors.join).to match(/scope/)
  end

  it "flags invalid date and time formats" do
    csv = "employee_code,work_date,check_in\nEMP001,01-06-2026,9am\n"
    errs = parse(csv).invalid_rows.first.errors.join
    expect(errs).to match(/work_date/)
    expect(errs).to match(/check_in/)
  end

  it "flags a row whose employee already has a record for that date" do
    create(:attendance_record, user: emp1, branch: create(:branch, business: business),
           date: Date.new(2026, 6, 1), work_date: Date.new(2026, 6, 1))
    result = parse("employee_code,work_date,check_in\nEMP001,2026-06-01,09:00\n")
    expect(result.invalid_count).to eq(1)
    expect(result.invalid_rows.first.duplicate).to be(true)
  end

  it "flags duplicate (employee, date) rows within the same file" do
    csv = <<~CSV
      employee_code,work_date,check_in
      EMP001,2026-06-01,09:00
      EMP001,2026-06-01,10:00
    CSV
    result = parse(csv)
    expect(result.valid_count).to eq(1)
    expect(result.invalid_rows.first.errors.join).to match(/Duplicate/i)
  end

  it "marks rows in a finalized payroll period as locked but still valid" do
    create(:payroll_period, :finalized, business: business,
           period_year: 2026, period_month: 6)
    result = parse("employee_code,work_date,check_in\nEMP001,2026-06-01,09:00\n")
    expect(result.valid_count).to eq(1)
    expect(result.valid_rows.first.locked).to be(true)
    expect(result.locked_count).to eq(1)
  end
end
