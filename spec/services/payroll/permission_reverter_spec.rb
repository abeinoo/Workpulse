require "rails_helper"

# Pilot 9 — Request Permission Payroll Effects, M4: Payroll::PermissionReverter,
# the Attendance & Payroll revert of a cancelled late / early-leave permission
# (moved from Requests::Canceller#rollback_permission, behaviour unchanged).
# Reached through Requests::PermissionPayrollEffects#permission_cancelled; the
# end-to-end cancellation behaviour stays pinned by
# spec/characterization/workforce/request_permission_payroll_effects_spec.rb.
RSpec.describe Payroll::PermissionReverter do
  around { |ex| travel_to(Time.zone.local(2026, 7, 15, 12, 0, 0)) { ex.run } }

  let(:business) { create(:business, working_days_per_month: 22) }
  let(:branch)   { create(:branch, business: business) }
  let(:employee) { create(:user, business: business) }
  let(:shift) do
    create(:shift, :fixed_time, business: business, start_time: Time.zone.parse("09:00"), end_time: Time.zone.parse("17:00"))
  end
  let(:assignment) do
    create(:shift_assignment, user: employee, branch: branch, shift: shift, effective_from: Date.new(2026, 1, 1))
  end
  let(:period) do # June 2026, daily rate 400
    create(:payroll_period, business: business, period_year: 2026, period_month: 6, working_days: 22, status: "under_review")
  end
  let(:work_date) { Date.new(2026, 6, 8) }
  let!(:attendance) do
    create(:attendance_record, user: employee, branch: branch, shift_assignment: assignment, date: work_date,
                               work_date: work_date, check_in_at: Time.zone.local(2026, 6, 8, 9, 40),
                               check_out_at: Time.zone.local(2026, 6, 8, 15, 0), worked_minutes: 320,
                               late_minutes: 40, early_leave_minutes: 120, status: "late")
  end
  let!(:entry) { create(:payroll_entry, payroll_period: period, user: employee, base_salary: 8_800, net_salary: 8_800) }

  before do
    create(:salary_profile, :monthly, user: employee, base_amount: 8_800.0, effective_from: Date.new(2026, 1, 1))
    create(:penalty_rule, shift: shift, rule_type: "late_arrival", threshold_minutes: 15,   # → −100
                          deduction_type: "percentage_of_daily", deduction_value: 25)
    create(:penalty_rule, shift: shift, rule_type: "early_leave", threshold_minutes: 30,    # → −200
                          deduction_type: "percentage_of_daily", deduction_value: 50)
  end

  def permission(type = :late_permission, date: work_date)
    build(:employee_request, type, :approved, user: employee, requested_for_date: date, duration_minutes: 40)
      .tap { |req| req.save!(validate: false) }
  end

  def line(type = "late_penalty")
    entry.payroll_line_items.find_by(item_type: type, source_type: "AttendanceRecord", source_id: attendance.id)
  end

  def reduced_line(type = "late_penalty", amount: -50.0, minutes: 40)
    create(:payroll_line_item, payroll_entry: entry, item_type: type, amount: amount, review_status: "approved",
                               source_type: "AttendanceRecord", source_id: attendance.id,
                               original_minutes: minutes, permission_minutes: 30)
  end

  it "1. open period: restores the line → :reverted" do
    reduced_line
    expect(described_class.call(permission)).to eq(:reverted)
    expect(line).to have_attributes(amount: -100.0, original_minutes: 40, permission_minutes: nil)
  end

  %w[finalized paid].each do |status|
    it "2/3. #{status} period → :refused, payroll untouched" do
      reduced = reduced_line
      period.update_column(:status, status)

      expect(described_class.call(permission)).to eq(:refused)
      expect(reduced.reload).to have_attributes(amount: -50.0, permission_minutes: 30)
    end
  end

  it "4. no payroll period for the month → :reverted, nothing created" do
    PayrollEntry.delete_all
    period.destroy!
    expect { expect(described_class.call(permission)).to eq(:reverted) }.not_to change(PayrollLineItem, :count)
  end

  it "5. no payroll entry → :reverted, nothing created" do
    entry.destroy!
    expect { expect(described_class.call(permission)).to eq(:reverted) }.not_to change(PayrollLineItem, :count)
  end

  it "6. no attendance record for the date → :reverted (even for a locked period)" do
    period.update_column(:status, "finalized")
    expect(described_class.call(permission(date: work_date + 1))).to eq(:reverted)
  end

  it "7. early leave: the matching early_leave_penalty line is restored; the late line untouched" do
    reduced_line("early_leave_penalty", amount: -100.0, minutes: 120)
    late = reduced_line("late_penalty")

    described_class.call(permission(:early_leave))
    expect(line("early_leave_penalty")).to have_attributes(amount: -200.0, original_minutes: 120, permission_minutes: nil)
    expect(late.reload).to have_attributes(amount: -50.0, permission_minutes: 30)
  end

  it "8. a deleted line is recreated with the full penalty and a generated description" do
    expect { described_class.call(permission) }.to change(PayrollLineItem, :count).by(1)
    expect(line).to have_attributes(amount: -100.0, original_minutes: 40, description: "Late arrival #{work_date}")
  end

  it "9. a penalty that is now zero deletes the line" do
    reduced_line
    attendance.update_column(:late_minutes, 10) # under the 15-minute threshold
    expect(described_class.call(permission)).to eq(:reverted)
    expect(line).to be_nil
  end

  it "zero raw minutes → :reverted, nothing touched" do
    reduced = reduced_line
    attendance.update_column(:late_minutes, 0)
    expect(described_class.call(permission)).to eq(:reverted)
    expect(reduced.reload.amount).to eq(-50.0)
  end

  it "10. recalculates the entry totals" do
    described_class.call(permission)
    expect(entry.reload).to have_attributes(total_deductions: 100.0, net_salary: 8_700.0)
  end

  it "11. uses the CURRENT attendance minutes, not the line's original_minutes" do
    reduced_line(minutes: 40)
    attendance.update_column(:late_minutes, 20)
    described_class.call(permission)
    expect(line).to have_attributes(original_minutes: 20)
  end

  it "12. never writes the attendance record" do
    reduced_line
    before = attendance.reload.attributes
    described_class.call(permission)
    expect(attendance.reload.attributes).to eq(before)
  end

  it "13. unexpected errors propagate (an invalid line item raises RecordInvalid)" do
    reduced_line
    allow_any_instance_of(PayrollLineItem).to receive(:update!).and_raise(ActiveRecord::RecordInvalid.new(PayrollLineItem.new))
    expect { described_class.call(permission) }.to raise_error(ActiveRecord::RecordInvalid)
  end

  it "a non-permission request → :reverted, nothing touched" do
    advance = build(:employee_request, :salary_advance, :approved, user: employee, requested_for_date: work_date)
    advance.save!(validate: false)
    expect { expect(described_class.call(advance)).to eq(:reverted) }.not_to change(PayrollLineItem, :count)
  end

  it "14. the contract hands the reverter the same request object" do
    req = permission
    allow(described_class).to receive(:call).and_return(:reverted)

    Requests::PermissionPayrollEffects.permission_cancelled(request: req)
    expect(described_class).to have_received(:call).with(req)
  end
end
