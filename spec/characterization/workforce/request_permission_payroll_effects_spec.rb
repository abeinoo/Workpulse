require "rails_helper"

# Characterization (Pilot 9 — Request Permission Payroll Effects, M1) — CURRENT
# behaviour of the payroll effect of late-permission and early-leave requests:
#
#   approve: Requests::Approver#approve_standard — request.update!(approved) →
#            Payroll::PermissionApplier.call(request) → log_audit("approve")
#            (no surrounding transaction)
#   cancel:  Requests::Canceller#cancel — in one transaction:
#            rollback_permission (re-derives the full penalty, restores /
#            recreates / destroys the line item) → request.update!(cancelled) →
#            log_audit("cancel")
#   payroll generation: Payroll::EntryCalculator subtracts
#            EmployeeRequest.approved_minutes from the penalised minutes
#
# Already pinned elsewhere, not repeated: PermissionApplier's per-threshold
# amounts (spec/services/payroll/permission_applier_spec.rb), early-leave
# cancellation restore + finalized / paid refusal (spec/services/requests/
# canceller_spec.rb), the approver calling PermissionApplier
# (spec/services/requests/approver_spec.rb), approve / cancel authorization
# (spec/requests/security/employee_request_*_spec.rb).
RSpec.describe "Characterization: request permission payroll effects" do
  around { |ex| travel_to(Time.zone.local(2026, 7, 15, 12, 0, 0)) { ex.run } }

  let(:business) { create(:business, working_days_per_month: 22) }
  let(:branch)   { create(:branch, business: business) }
  let(:employee) { create(:user, business: business) }
  let(:reviewer) { create(:user, :owner, business: business) }
  let(:shift) do
    create(:shift, :fixed_time, business: business, start_time: Time.zone.parse("09:00"), end_time: Time.zone.parse("17:00"))
  end
  let!(:assignment) do
    create(:shift_assignment, user: employee, branch: branch, shift: shift, effective_from: Date.new(2026, 1, 1))
  end
  let(:period) do # June 2026, daily rate 8,800 / 22 = 400
    create(:payroll_period, business: business, period_year: 2026, period_month: 6, working_days: 22, status: "under_review")
  end
  let(:work_date) { Date.new(2026, 6, 8) } # a Monday

  before do
    create(:salary_profile, :monthly, user: employee, base_amount: 8_800.0, effective_from: Date.new(2026, 1, 1))
    # late: > 15 min → 25 % of the daily rate (100); early leave: > 30 min → 50 % (200)
    create(:penalty_rule, shift: shift, rule_type: "late_arrival", threshold_minutes: 15,
                          deduction_type: "percentage_of_daily", deduction_value: 25)
    create(:penalty_rule, shift: shift, rule_type: "early_leave", threshold_minutes: 30,
                          deduction_type: "percentage_of_daily", deduction_value: 50)
  end

  def at(hour, minute = 0) = Time.zone.local(work_date.year, work_date.month, work_date.day, hour, minute)

  # One record carrying BOTH a 40-minute late arrival and a 120-minute early
  # leave, so each permission type can be checked against the other's line.
  def attendance(late: 40, early: 120)
    @attendance ||= create(:attendance_record, user: employee, branch: branch, shift_assignment: assignment,
                                               date: work_date, work_date: work_date,
                                               check_in_at: at(9, late), check_out_at: at(17) - early.minutes,
                                               worked_minutes: 480 - late - early, late_minutes: late,
                                               early_leave_minutes: early, status: "late")
  end

  def entry
    @entry ||= create(:payroll_entry, payroll_period: period, user: employee, base_salary: 8_800, net_salary: 8_500,
                                      needs_review: false)
  end

  def penalty_line(item_type, amount, minutes)
    create(:payroll_line_item, payroll_entry: entry, item_type: item_type, amount: amount, review_status: "approved",
                               source_type: "AttendanceRecord", source_id: attendance.id,
                               original_minutes: minutes, permission_minutes: 0)
  end

  def permission(type, minutes, status: :pending)
    build(:employee_request, type, status, user: employee, requested_for_date: work_date, duration_minutes: minutes)
      .tap { |req| req.save!(validate: false) }
  end

  def approve(req)  = Requests::Approver.approve(request: req, reviewed_by: reviewer)
  def cancel(req)   = Requests::Canceller.cancel(request: req, cancelled_by: reviewer, reason: "characterization")
  def line(type)    = entry.payroll_line_items.find_by(item_type: type, source_type: "AttendanceRecord", source_id: attendance.id)
  def audits(req)   = AuditLog.where(auditable: req).order(:id).pluck(:action)

  {
    late_permission: { item_type: "late_penalty", other: "early_leave_penalty", raw: 40, amount: -100.0,
                       above_threshold: 10, below_threshold: 30, label: "Late arrival" },
    early_leave:     { item_type: "early_leave_penalty", other: "late_penalty", raw: 120, amount: -200.0,
                       above_threshold: 60, below_threshold: 100, label: "Early leave" }
  }.each do |type, c|
    describe type.to_s do
      let!(:own_line)   { penalty_line(c[:item_type], c[:amount], c[:raw]) }
      let!(:other_line) do
        other_amount, other_minutes = c[:other] == "late_penalty" ? [ -100.0, 40 ] : [ -200.0, 120 ]
        penalty_line(c[:other], other_amount, other_minutes)
      end

      before { entry.recalculate_totals! && entry.update_column(:needs_review, false) }

      describe "approval (pending → approved)" do
        it "partial cover, still over the threshold: the line keeps its amount and records original / permission minutes" do
          req = permission(type, c[:above_threshold])
          result = approve(req)

          expect(result).to be_success
          expect(req.reload.status).to eq("approved")
          expect(own_line.reload).to have_attributes(amount: c[:amount], original_minutes: c[:raw],
                                                     permission_minutes: c[:above_threshold])
        end

        it "cover below the threshold: the line is destroyed and the entry totals are recalculated" do
          before_deductions = entry.reload.total_deductions
          approve(permission(type, c[:below_threshold]))

          expect(line(c[:item_type])).to be_nil
          expect(entry.reload.total_deductions).to eq(before_deductions - c[:amount].abs)
          expect(entry.net_salary).to eq(8_800 - entry.total_deductions)
          expect(entry.needs_review).to be(true) # the totals changed in an open period
        end

        it "touches only its own line type on the shared attendance record" do
          approve(permission(type, c[:below_threshold]))
          expect(other_line.reload).to have_attributes(original_minutes: other_line.original_minutes, permission_minutes: 0)
        end

        it "audits the approval on the request only — no audit or payroll audit row for the line change" do
          req = permission(type, c[:below_threshold])
          expect { approve(req) }.not_to change(PayrollAuditLog, :count)
          expect(audits(req)).to eq([ "approve" ])
          expect(AuditLog.where(auditable_type: "PayrollLineItem")).to be_empty
        end

        %w[finalized paid].each do |status|
          it "#{status} period: approval succeeds, payroll is not touched" do
            period.update_column(:status, status)
            req = permission(type, c[:below_threshold])

            expect(approve(req)).to be_success
            expect(req.reload.status).to eq("approved")
            expect(own_line.reload.amount).to eq(c[:amount])
          end
        end

        it "no payroll period for the month: approval succeeds, nothing else happens" do
          PayrollLineItem.delete_all
          PayrollEntry.delete_all
          period.destroy!
          expect { approve(permission(type, c[:below_threshold])) }.not_to change(PayrollEntry, :count)
        end

        it "no payroll entry for the employee: approval succeeds; no entry or line is created" do
          PayrollLineItem.delete_all
          PayrollEntry.delete_all
          req = permission(type, c[:below_threshold])

          expect { approve(req) }.not_to change { [ PayrollEntry.count, PayrollLineItem.count ] }
          expect(req.reload.status).to eq("approved")
        end

        it "no attendance record for the date: approval succeeds, payroll is not touched" do
          req = build(:employee_request, type, :pending, user: employee, requested_for_date: work_date + 1,
                                                            duration_minutes: c[:below_threshold])
          req.save!(validate: false)

          expect(approve(req)).to be_success
          expect(own_line.reload.amount).to eq(c[:amount])
        end

        it "no matching penalty line on the attendance record: nothing is created" do
          own_line.destroy!
          expect { approve(permission(type, c[:below_threshold])) }.not_to change(PayrollLineItem, :count)
        end

        it "a second approved permission for the same day replaces, not adds to, the first (minutes from original_minutes)" do
          approve(permission(type, c[:above_threshold]))
          approve(permission(type, 1))

          expect(own_line.reload).to have_attributes(original_minutes: c[:raw], permission_minutes: 1, amount: c[:amount])
        end

        it "a failure inside the applier is not rescued: the request stays approved, no approve audit, payroll unchanged" do
          req = permission(type, c[:below_threshold])
          allow(Payroll::PermissionApplier).to receive(:call).and_raise(StandardError, "boom")

          expect { approve(req) }.to raise_error(StandardError, "boom")
          expect(req.reload.status).to eq("approved")
          expect(audits(req)).to be_empty
          expect(own_line.reload.amount).to eq(c[:amount])
        end
      end

      describe "cancellation (approved → cancelled) — Requests::Canceller#rollback_permission" do
        it "after a partial cover: restores the full penalty, clears permission_minutes, recalculates totals" do
          req = permission(type, c[:above_threshold])
          approve(req)
          result = cancel(req)

          expect(result).to be_success
          expect(req.reload.status).to eq("cancelled")
          expect(own_line.reload).to have_attributes(amount: c[:amount], original_minutes: c[:raw], permission_minutes: nil)
          expect(audits(req)).to eq(%w[approve cancel])
        end

        it "after the line was destroyed: recreates it with the full penalty and a generated description" do
          req = permission(type, c[:below_threshold])
          approve(req)
          expect(line(c[:item_type])).to be_nil

          expect { cancel(req) }.to change(PayrollLineItem, :count).by(1)
          expect(line(c[:item_type])).to have_attributes(amount: c[:amount], original_minutes: c[:raw],
                                                         description: "#{c[:label]} #{work_date}")
          expect(entry.reload.total_deductions).to eq(300.0) # both penalties back
        end

        it "re-derives the penalty from the CURRENT attendance minutes, not the minutes snapshotted on the line" do
          req = permission(type, c[:below_threshold])
          approve(req)
          column = type == :late_permission ? :late_minutes : :early_leave_minutes
          attendance.update_column(column, 5) # below the threshold now

          cancel(req)
          expect(line(c[:item_type])).to be_nil
          expect(req.reload.status).to eq("cancelled")
        end

        it "touches only its own line type" do
          req = permission(type, c[:below_threshold])
          approve(req)
          other_before = other_line.reload.attributes.except("updated_at")

          cancel(req)
          expect(other_line.reload.attributes.except("updated_at")).to eq(other_before)
        end

        %w[finalized paid].each do |status|
          it "#{status} period: refused with the 'cannot cancel finalized' error; request, payroll and audit unchanged" do
            req = permission(type, c[:below_threshold])
            approve(req)
            period.update_column(:status, status)

            result = cancel(req)
            expect(result).not_to be_success
            expect(result.error).to eq(I18n.t("requests.errors.cannot_cancel_finalized"))
            expect(req.reload.status).to eq("approved")
            expect(line(c[:item_type])).to be_nil
            expect(audits(req)).to eq([ "approve" ])
          end
        end

        it "no payroll entry: cancelled, nothing created" do
          req = permission(type, c[:below_threshold], status: :approved)
          PayrollLineItem.delete_all
          PayrollEntry.delete_all

          expect { cancel(req) }.not_to change(PayrollLineItem, :count)
          expect(req.reload.status).to eq("cancelled")
        end

        it "no payroll period: cancelled, nothing created" do
          req = permission(type, c[:below_threshold], status: :approved)
          PayrollLineItem.delete_all
          PayrollEntry.delete_all
          period.destroy!

          expect(cancel(req)).to be_success
          expect(req.reload.status).to eq("cancelled")
        end

        it "no attendance record for the date: cancelled, payroll untouched" do
          req = build(:employee_request, type, :approved, user: employee, requested_for_date: work_date + 1,
                                                             duration_minutes: c[:below_threshold])
          req.save!(validate: false)

          expect(cancel(req)).to be_success
          expect(own_line.reload.amount).to eq(c[:amount])
        end

        it "no raw minutes on the attendance record: cancelled, payroll untouched" do
          req = permission(type, c[:below_threshold], status: :approved)
          column = type == :late_permission ? :late_minutes : :early_leave_minutes
          attendance.update_column(column, 0)

          expect { cancel(req) }.not_to change { own_line.reload.attributes }
          expect(req.reload.status).to eq("cancelled")
        end

        it "a failure while restoring is not rescued, but the cancel transaction rolls back: request approved, no cancel audit" do
          req = permission(type, c[:below_threshold])
          approve(req)
          allow(Attendance::PenaltyCalculator).to receive(:calculate).and_raise(StandardError, "boom")

          expect { cancel(req) }.to raise_error(StandardError, "boom")
          expect(req.reload.status).to eq("approved")
          expect(line(c[:item_type])).to be_nil
          expect(audits(req)).to eq([ "approve" ])
        end

        it "uses Salary::DailyRateCalculator and Attendance::PenaltyCalculator (the helpers shared with punch-correction rollback)" do
          req = permission(type, c[:below_threshold])
          approve(req)
          allow(Salary::DailyRateCalculator).to receive(:for).and_call_original
          allow(Attendance::PenaltyCalculator).to receive(:calculate).and_call_original

          cancel(req)
          expect(Salary::DailyRateCalculator).to have_received(:for).with(user: employee, business: business, date: period.period_start)
          expect(Attendance::PenaltyCalculator).to have_received(:calculate).once
        end

        it "does not touch the attendance record" do
          req = permission(type, c[:below_threshold])
          approve(req)
          before = attendance.reload.attributes

          cancel(req)
          expect(attendance.reload.attributes).to eq(before)
        end
      end

      describe "payroll generated after approval (Payroll::EntryCalculator)" do
        it "subtracts the approved minutes when the entry is generated; cancelling restores the full penalty" do
          PayrollLineItem.delete_all
          PayrollEntry.delete_all
          @entry = nil
          req = permission(type, c[:below_threshold])
          approve(req)

          generated = Payroll::EntryCalculator.call(period: period, user: employee, business: business)
          @entry = generated
          expect(line(c[:item_type])).to be_nil

          cancel(req)
          expect(line(c[:item_type])).to have_attributes(amount: c[:amount], original_minutes: c[:raw])
        end
      end
    end
  end

  describe "the effect path goes through the request policy (web)", type: :request do
    it "an approver outside the employee's approve_requests scope cannot trigger the payroll effect" do
      own = penalty_line("late_penalty", -100.0, 40)
      req = permission(:late_permission, 30)
      outsider = api_user_with(business, :view_requests, :approve_requests,
                               scopes: { "view_requests" => "business", "approve_requests" => "self" })
      sign_in outsider

      patch approve_employee_request_path(req)

      expect(response).to redirect_to(root_path)
      expect(req.reload.status).to eq("pending")
      expect(own.reload).to have_attributes(amount: -100.0, permission_minutes: 0)
    end
  end
end
