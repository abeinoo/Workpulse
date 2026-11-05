require "rails_helper"

# Payroll::UnsalariedAttendance — the period page's warning: attendance on days
# with no salary profile in force (unpaid), and whether the employee is in the
# payroll at all.
RSpec.describe Payroll::UnsalariedAttendance do
  let(:business) { create(:business, working_days_per_month: 26, timezone: "UTC") }
  let(:branch)   { create(:branch, business: business) }
  let(:shift)    { create(:shift, :fixed_time, business: business) }
  let(:period)   { create(:payroll_period, business: business, period_year: 2026, period_month: 10, working_days: 26) }

  def oct(day) = Date.new(2026, 10, day)

  def employee_working(*days, name: "Omar")
    create(:user, business: business, first_name: name, last_name: "Test").tap do |user|
      assignment = create(:shift_assignment, user: user, branch: branch, shift: shift, effective_from: Date.new(2026, 1, 1))
      days.each do |d|
        create(:attendance_record, user: user, branch: branch, shift_assignment: assignment, date: oct(d), work_date: oct(d),
               check_in_at: Time.zone.local(2026, 10, d, 9), check_out_at: Time.zone.local(2026, 10, d, 17),
               worked_minutes: 480, late_minutes: 0, early_leave_minutes: 0, status: "present")
      end
    end
  end

  def rows(users = business.users) = described_class.new(period: period, users: users).rows

  it "lists an employee with attendance and no salary profile as not in payroll" do
    omar = employee_working(3, 10)
    row = rows.sole

    expect(row).to have_attributes(user: omar, unpaid_days: 2, first_date: oct(3), last_date: oct(10))
    expect(row).not_to be_in_payroll
  end

  it "counts only the days before the first profile, never borrowing a later profile" do
    omar = employee_working(3, 10, 25, 26)
    create(:salary_profile, :daily, user: omar, base_amount: 300, effective_from: oct(25))
    create(:payroll_entry, payroll_period: period, user: omar)

    row = rows.sole
    expect(row).to have_attributes(unpaid_days: 2, first_date: oct(3), last_date: oct(10))
    expect(row).to be_in_payroll
  end

  it "lists a profile effective after the period as not covering any day" do
    omar = employee_working(3)
    create(:salary_profile, :daily, user: omar, base_amount: 300, effective_from: Date.new(2026, 11, 3))
    expect(rows.sole).to have_attributes(user: omar, unpaid_days: 1)
  end

  it "omits employees whose every attendance day has a profile in force" do
    sara = employee_working(3, 10, name: "Sara")
    create(:salary_profile, :monthly, user: sara, base_amount: 9_000, effective_from: Date.new(2026, 1, 1))
    expect(rows).to be_empty
  end

  it "ignores attendance outside the period" do
    omar = employee_working(3)
    AttendanceRecord.where(user: omar).update_all(work_date: Date.new(2026, 11, 1))
    expect(rows).to be_empty
  end

  it "is limited to the employees it is given (the viewer's scope)" do
    employee_working(3)
    expect(rows(User.none)).to be_empty
  end

  it "never lists another business's employees" do
    employee_working(3)
    other = create(:payroll_period, business: create(:business), period_year: 2026, period_month: 10, working_days: 26)
    expect(described_class.new(period: other, users: User.all).rows).to be_empty
  end
end
