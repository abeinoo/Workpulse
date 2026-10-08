require "rails_helper"

# Pilot 10 unblock (product decision): a punch correction is NOT approved when
# the payroll period of its date is finalized or paid. Before, approval rewrote
# the attendance record while the frozen payroll stayed as it was, and the
# cancellation was then refused for the same period — a permanent attendance /
# payroll mismatch. The guard runs inside the approval's existing transaction,
# before anything is written (Requests::PunchCorrectionApplier), so a refused
# approval leaves request, snapshot, attendance, payroll and audit untouched.
RSpec.describe "Punch correction approval in a locked payroll period", type: :request do
  around { |ex| travel_to(Time.zone.local(2026, 7, 15, 12, 0, 0)) { ex.run } }

  let(:business) { create(:business, working_days_per_month: 22) } # Asia/Riyadh
  let(:tz)       { ActiveSupport::TimeZone[business.timezone] }
  let(:branch)   { create(:branch, business: business) }
  let(:employee) { create(:user, business: business) }
  let(:reviewer) { create(:user, :owner, business: business) }
  let(:shift) do
    create(:shift, :fixed_time, business: business, start_time: Time.zone.parse("09:00"), end_time: Time.zone.parse("17:00"))
  end
  let!(:assignment) do
    create(:shift_assignment, user: employee, branch: branch, shift: shift, effective_from: Date.new(2026, 1, 1))
  end
  let(:period) do
    create(:payroll_period, business: business, period_year: 2026, period_month: 6, working_days: 22, status: "under_review")
  end
  let(:day) { Date.new(2026, 6, 8) }
  let!(:record) do
    create(:attendance_record, user: employee, branch: branch, shift_assignment: assignment, date: day, work_date: day,
                               check_in_at: tz.local(2026, 6, 8, 9, 40), check_out_at: tz.local(2026, 6, 8, 17, 0),
                               late_minutes: 40, early_leave_minutes: 0, worked_minutes: 440, status: "late")
  end
  let!(:entry) { create(:payroll_entry, payroll_period: period, user: employee, base_salary: 8_800, net_salary: 8_700) }
  let!(:line) do
    create(:payroll_line_item, payroll_entry: entry, item_type: "late_penalty", amount: -100.0, review_status: "approved",
                               source_type: "AttendanceRecord", source_id: record.id, original_minutes: 40)
  end

  before do
    create(:salary_profile, :monthly, user: employee, base_amount: 8_800.0, effective_from: Date.new(2026, 1, 1))
    create(:penalty_rule, shift: shift, rule_type: "late_arrival", threshold_minutes: 15,
                          deduction_type: "percentage_of_daily", deduction_value: 25)
  end

  def correction(date: day)
    build(:employee_request, :punch_correction, :pending, user: employee, requested_for_date: date,
                                                          correction_type: "wrong_check_in_time", proposed_time: "09:00",
                                                          proposed_date: date)
      .tap { |req| req.save!(validate: false) }
  end

  def approve(req) = Requests::Approver.approve(request: req, reviewed_by: reviewer, confirm_out_of_window: true)

  def snapshot(req)
    { request: req.reload.attributes.slice(*%w[status approved_punch_at reviewed_by_id reviewed_at original_check_in_at
                                               original_check_out_at original_check_in_source original_check_out_source]),
      record:  record.reload.attributes.except("updated_at"),
      line:    line.reload.attributes.except("updated_at"),
      entry:   entry.reload.attributes.except("updated_at") }
  end

  %w[finalized paid].each do |status|
    describe "#{status} period" do
      before { period.update_column(:status, status) }

      it "8/9. refuses the approval with the cannot_approve_finalized error" do
        result = approve(correction)

        expect(result).not_to be_success
        expect(result.error).to eq(I18n.t("requests.errors.cannot_approve_finalized"))
      end

      it "10–15. leaves the request pending, approved_punch_at and snapshot unset, attendance, payroll and audit untouched" do
        req    = correction
        before = snapshot(req)

        approve(req)

        expect(snapshot(req)).to eq(before)
        expect(req.status).to eq("pending")
        expect(req.approved_punch_at).to be_nil
        expect(req.original_check_in_at).to be_nil
        expect(AuditLog.where(auditable: req, action: "approve")).to be_empty
      end

      it "through the web: redirect with the alert, request still pending" do
        req = correction
        sign_in reviewer
        patch approve_employee_request_path(req), params: { confirm_out_of_window: "1" }

        expect(flash[:alert]).to eq(I18n.t("requests.errors.cannot_approve_finalized"))
        expect(req.reload.status).to eq("pending")
        expect(record.reload.check_in_at).to eq(tz.local(2026, 6, 8, 9, 40))
      end
    end
  end

  it "16. open period: approval unchanged — snapshot written, attendance corrected and recomputed, penalty line removed" do
    req    = correction
    result = approve(req)

    expect(result).to be_success
    expect(req.reload).to have_attributes(status: "approved", original_check_in_at: tz.local(2026, 6, 8, 9, 40))
    expect(record.reload).to have_attributes(check_in_at: tz.local(2026, 6, 8, 9, 0), late_minutes: 0)
    expect(PayrollLineItem.exists?(line.id)).to be(false)
    expect(AuditLog.where(auditable: req, action: "approve")).to exist
  end

  it "17. no payroll period for the month: approval unchanged — attendance corrected, no payroll touched" do
    PayrollLineItem.delete_all
    PayrollEntry.delete_all
    period.destroy!

    result = approve(correction)
    expect(result).to be_success
    expect(record.reload.check_in_at).to eq(tz.local(2026, 6, 8, 9, 0))
  end

  it "a missing attendance record still answers with the existing message first (even in a locked period)" do
    period.update_column(:status, "finalized")
    req = correction(date: day + 1)

    result = approve(req)
    expect(result.error).to eq("No attendance record found for #{day + 1}")
    expect(req.reload.status).to eq("pending")
  end

  it "a locked period does not affect permissions: late-permission approval still succeeds (Pilot 9 unchanged)" do
    period.update_column(:status, "finalized")
    permission = build(:employee_request, :late_permission, :pending, user: employee, requested_for_date: day,
                                                                       duration_minutes: 40)
                 .tap { |r| r.save!(validate: false) }

    expect(approve(permission)).to be_success
    expect(line.reload.amount).to eq(-100.0)
  end
end
