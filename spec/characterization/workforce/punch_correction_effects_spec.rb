require "rails_helper"

# Characterization (Pilot 10 — Punch Correction, M1) — CURRENT attendance and
# payroll effects of approving and cancelling a punch correction, the parts the
# future Workforce → Attendance & Payroll contract will carry:
#
#   approve: Requests::Approver#approve_punch_correction — one transaction:
#            request approved + approved_punch_at → Requests::PunchCorrectionApplier
#            (snapshot onto the request, punch written, Attendance::RecordRecomputer)
#            → Payroll::PunchCorrectionApplier (existing penalty lines of an open
#            period updated / deleted, totals) — then log_audit("approve")
#   cancel:  Requests::Canceller#cancel — one transaction: rollback_punch_correction
#            (snapshot restored, recompute) → rollback_punch_payroll (lines
#            updated / RECREATED / deleted, totals) → cancelled → log_audit("cancel")
#
# Since M4-2 both effects run in Attendance::PunchCorrectionEffects behind the
# Workforce contract; since M4-3 their payroll part is the entry's full
# recalculation (Payroll::EntryRecalculator; Decisions A / B / C). The payroll
# groups therefore give the employee a complete June (complete_rest_of_month!)
# so the hand-built entry equals what that recalculation derives. Examples
# whose expectation changed in M4-3 say so ("CHANGED in M4-3").
#
# Already pinned elsewhere, not repeated: field updates, overnight dates and the
# reviewer's date / time (spec/services/requests/punch_correction_applier_spec.rb,
# spec/requests/employee_request_reviewer_datetime_spec.rb), the attendance window,
# duration severity and confirmation gate (punch_correction_window_guard_spec.rb,
# employee_request_attendance_window_spec.rb, employee_request_resulting_duration_spec.rb),
# punch order (employee_request_check_out_order_spec.rb), submitter / self-approval /
# scope (spec/requests/security/employee_request_submitter_spec.rb, the SEC-P9-1
# specs), locked-period approval and the no-period case
# (spec/requests/security/punch_correction_locked_period_spec.rb).
RSpec.describe "Characterization: punch correction attendance and payroll effects" do
  around { |ex| travel_to(Time.zone.local(2026, 7, 15, 12, 0, 0)) { ex.run } }

  let(:business) { create(:business, working_days_per_month: 22) } # Asia/Riyadh, daily rate 8,800 / 22 = 400
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
  let(:period) do # June 2026
    create(:payroll_period, business: business, period_year: 2026, period_month: 6, working_days: 22, status: "under_review")
  end
  let(:day) { Date.new(2026, 6, 8) } # Monday

  before do
    create(:salary_profile, :monthly, user: employee, base_amount: 8_800.0, effective_from: Date.new(2026, 1, 1))
    # late > 15 min → 25 % of the daily rate (−100); early leave > 30 min → 50 % (−200)
    create(:penalty_rule, shift: shift, rule_type: "late_arrival", threshold_minutes: 15,
                          deduction_type: "percentage_of_daily", deduction_value: 25)
    create(:penalty_rule, shift: shift, rule_type: "early_leave", threshold_minutes: 30,
                          deduction_type: "percentage_of_daily", deduction_value: 50)
  end

  def at(hour, minute = 0, date: day) = tz.local(date.year, date.month, date.day, hour, minute)

  # Default: 40 minutes late (09:40) and 120 minutes early (15:00).
  def attendance(check_in: at(9, 40), check_out: at(15, 0), late: 40, early: 120)
    @attendance ||= create(:attendance_record, user: employee, branch: branch, shift_assignment: assignment,
                                               date: day, work_date: day, check_in_at: check_in, check_out_at: check_out,
                                               check_in_source: "device", check_out_source: "device",
                                               late_minutes: late, early_leave_minutes: early,
                                               worked_minutes: check_out ? ((check_out - check_in) / 60).to_i : nil,
                                               status: "late")
  end

  # Complete, on-time attendance on June's other 21 working days. Since M4-3
  # (Decision C) approval and cancellation re-derive the whole entry from the
  # month's attendance; with these days the hand-built entry below (22 days
  # worked, base 8,800, only the corrected day's penalties) is exactly what that
  # recalculation produces, so the examples keep measuring the corrected day
  # rather than a 21-day absence deduction of a one-day fixture month.
  def complete_rest_of_month!
    (Date.new(2026, 6, 1)..Date.new(2026, 6, 30)).select { |d| d.on_weekday? && d != day }.each do |d|
      create(:attendance_record, user: employee, branch: branch, shift_assignment: assignment, date: d, work_date: d,
                                 check_in_at: at(9, 0, date: d), check_out_at: at(17, 0, date: d),
                                 check_in_source: "device", check_out_source: "device", status: "present")
        .tap { |record| Attendance::RecordRecomputer.recompute!(record) && record.save! }
    end
  end

  def entry(**attrs)
    @entry ||= create(:payroll_entry, { payroll_period: period, user: employee, base_salary: 8_800, net_salary: 8_500,
                                        needs_review: false }.merge(attrs))
  end

  def penalty_line(item_type, amount, minutes, permission_minutes: 0)
    create(:payroll_line_item, payroll_entry: entry, item_type: item_type, amount: amount, review_status: "approved",
                               source_type: "AttendanceRecord", source_id: attendance.id, original_minutes: minutes,
                               permission_minutes: permission_minutes)
  end

  def line(type) = entry.payroll_line_items.find_by(item_type: type, source_type: "AttendanceRecord", source_id: attendance.id)

  def correction(type, time, date: day)
    build(:employee_request, :punch_correction, :pending, user: employee, requested_for_date: date, correction_type: type,
                                                          proposed_time: time, proposed_date: date)
      .tap { |req| req.save!(validate: false) }
  end

  def approve(req, **opts) = Requests::Approver.approve(request: req, reviewed_by: reviewer, confirm_out_of_window: true, **opts)
  def cancel(req)          = Requests::Canceller.cancel(request: req, cancelled_by: reviewer, reason: "characterization")
  def audits(req)          = AuditLog.where(auditable: req).order(:id).pluck(:action)

  def snapshot_state(req)
    { request: req.reload.attributes.slice(*%w[status approved_punch_at reviewed_by_id original_check_in_at
                                               original_check_out_at original_check_in_source original_check_out_source]),
      record:  attendance.reload.attributes.except("updated_at"),
      lines:   entry.payroll_line_items.reload.order(:id).map { |li| li.attributes.except("updated_at") },
      entry:   entry.reload.attributes.except("updated_at") }
  end

  # ── E. approval: payroll penalty effect ────────────────────────────────────
  describe "E. approval — the penalty lines of the open period" do
    before do
      complete_rest_of_month!
      penalty_line("late_penalty", -100.0, 40)
      penalty_line("early_leave_penalty", -200.0, 120)
      entry.recalculate_totals!
      entry.update_column(:needs_review, false)
    end

    it "check-in still over the threshold: the late line keeps its amount, original_minutes follows the new lateness" do
      approve(correction("wrong_check_in_time", "09:20"))

      expect(attendance.reload).to have_attributes(check_in_at: at(9, 20), late_minutes: 20)
      expect(line("late_penalty")).to have_attributes(amount: -100.0, original_minutes: 20)
      expect(entry.reload).to have_attributes(total_deductions: 300.0, needs_review: false) # totals unchanged → no flag
    end

    it "check-in removes the lateness: the late line is deleted, the early line untouched, totals recalculated, needs_review set" do
      approve(correction("wrong_check_in_time", "09:00"))

      expect(attendance.reload.late_minutes).to eq(0)
      expect(line("late_penalty")).to be_nil
      expect(line("early_leave_penalty")).to have_attributes(amount: -200.0, original_minutes: 120)
      expect(entry.reload).to have_attributes(total_deductions: 200.0, net_salary: 8_600.0, needs_review: true)
    end

    it "check-out still over the threshold: the early line keeps its amount with the new minutes; the late line untouched" do
      approve(correction("wrong_check_out_time", "16:00"))

      expect(attendance.reload).to have_attributes(check_out_at: at(16, 0), early_leave_minutes: 60)
      expect(line("early_leave_penalty")).to have_attributes(amount: -200.0, original_minutes: 60)
      expect(line("late_penalty")).to have_attributes(amount: -100.0, original_minutes: 40)
    end

    it "check-out under the threshold: the early line is deleted (computed penalty 0)" do
      approve(correction("wrong_check_out_time", "16:50"))

      expect(attendance.reload.early_leave_minutes).to eq(10)
      expect(line("early_leave_penalty")).to be_nil
      expect(entry.reload.total_deductions).to eq(100.0)
    end

    # CHANGED in M4-3 (Decision B). Until M4-2 the approval recomputed the line
    # from the full new minutes and ignored the permission (35 minutes → −100,
    # permission_minutes 30 kept on the line). The entry is now re-derived by
    # Payroll::EntryRecalculator, which deducts the approved permission minutes
    # before the penalty rules apply.
    it "respects an approved late permission: only the minutes beyond it are penalised (Decision B)" do
      create(:employee_request, :late_permission, status: "approved", user: employee, requested_for_date: day,
                                                  duration_minutes: 30, reviewed_by: reviewer)
      approve(correction("wrong_check_in_time", "09:35"))

      expect(attendance.reload.late_minutes).to eq(35)
      expect(line("late_penalty")).to be_nil # 35 − 30 = 5 minutes, under the 15-minute threshold
      expect(entry.reload.total_deductions).to eq(200.0)
    end

    it "respects an approved late permission that does not cover all the lateness (Decision B)" do
      create(:employee_request, :late_permission, status: "approved", user: employee, requested_for_date: day,
                                                  duration_minutes: 30, reviewed_by: reviewer)
      approve(correction("wrong_check_in_time", "10:00"))

      expect(line("late_penalty")).to have_attributes(amount: -100.0, original_minutes: 60, permission_minutes: 30)
    end
  end

  describe "E. approval — lines are derived from attendance (Decisions A / C)" do
    before { complete_rest_of_month! }

    # CHANGED in M4-3 (Decision A). Until M4-2 only existing lines were updated:
    # a correction that introduced lateness changed attendance but created no
    # line. The recalculation creates the line the corrected punch requires.
    # (An on-time, full day here, so only the corrected lateness is in play.)
    it "a correction that introduces lateness creates the late line it requires (Decision A)" do
      attendance(check_in: at(9, 0), late: 0, check_out: at(17, 0), early: 0)
      entry
      approve(correction("wrong_check_in_time", "09:45"))

      expect(attendance.reload.late_minutes).to eq(45)
      expect(line("late_penalty")).to have_attributes(amount: -100.0, original_minutes: 45, permission_minutes: 0,
                                                      description: "Late arrival #{day}")
      expect(entry.reload.total_deductions).to eq(100.0)
    end

    it "an open period without a payroll entry: attendance corrected, no entry created" do
      attendance
      period
      expect { approve(correction("wrong_check_in_time", "09:00")) }.not_to change(PayrollEntry, :count)
      expect(attendance.reload.late_minutes).to eq(0)
    end

    # CHANGED in M4-3 (Decision C). Until M4-2 only penalty lines were patched:
    # completing an incomplete day left days_worked as stored (5). The entry is
    # now re-derived, so the completed day counts: the 21 other complete days + 1.
    it "worked days are re-derived: completing an incomplete day counts it (Decision C)" do
      attendance(check_out: nil, early: 0).update_columns(status: "incomplete", worked_minutes: nil)
      entry(days_worked: 5)
      approve(correction("missing_check_out", "17:00"))

      expect(attendance.reload).to have_attributes(check_out_at: at(17, 0), status: "late")
      expect(entry.reload).to have_attributes(days_worked: 22, base_salary: 8_800.0)
      expect(line("late_penalty")).to have_attributes(amount: -100.0, original_minutes: 40)
    end

    it "overtime is re-derived: a later check-out creates the overtime line it earns (Decision C)" do
      attendance(check_in: at(9, 0), late: 0, check_out: at(17, 0), early: 0)
      entry
      approve(correction("wrong_check_out_time", "19:00"))

      expect(line("overtime")).to be_present
      expect(entry.reload.total_overtime).to be > 0
      expect(entry.calculated_overtime_pay).to eq(entry.total_overtime)
    end
  end

  # ── F. approval atomicity ──────────────────────────────────────────────────
  describe "F. approval atomicity" do
    before do
      complete_rest_of_month!
      penalty_line("late_penalty", -100.0, 40)
      entry.recalculate_totals!
    end

    it "a failure in the payroll effect rolls everything back: pending, no approved_punch_at, no snapshot, attendance and payroll untouched, no approve audit" do
      req    = correction("wrong_check_in_time", "09:00")
      before = snapshot_state(req)
      # The payroll effect is Payroll::EntryRecalculator since M4-3 (was Payroll::PunchCorrectionApplier).
      allow(Payroll::EntryRecalculator).to receive(:call).and_raise(StandardError, "boom")

      result = approve(req)

      expect(result).not_to be_success
      expect(result.error).to eq("boom") # Requests::PunchCorrectionApplier turns any error into its message
      expect(snapshot_state(req)).to eq(before)
      expect(audits(req)).to be_empty
    end

    it "a failure while recomputing the persisted attendance record rolls back the same way" do
      req    = correction("wrong_check_in_time", "09:00")
      before = snapshot_state(req)
      # The pre-approval assessment also recomputes an UNSAVED copy (outside the
      # transaction); only the applier's recompute of the real record fails here.
      allow(Attendance::RecordRecomputer).to receive(:recompute!).and_wrap_original do |original, record|
        raise StandardError, "recompute failed" if record.persisted?

        original.call(record)
      end

      expect(approve(req).error).to eq("recompute failed")
      expect(snapshot_state(req)).to eq(before)
    end

    it "the approve audit is written only after the transaction: the payroll effect runs before it exists" do
      req  = correction("wrong_check_in_time", "09:00")
      seen = nil
      allow(Payroll::EntryRecalculator).to receive(:call).and_wrap_original do |original, **kwargs| # payroll effect since M4-3
        seen = AuditLog.exists?(auditable: req, action: "approve")
        original.call(**kwargs)
      end

      approve(req)
      expect(seen).to be(false)
      expect(audits(req)).to eq([ "approve" ])
    end

    it "an audit write failure after commit is swallowed: the approval and its effects stay, no audit row" do
      req = correction("wrong_check_in_time", "09:00")
      allow(AuditLog).to receive(:create!).and_raise(ActiveRecord::RecordInvalid.new(AuditLog.new))

      expect(approve(req)).to be_success
      expect(req.reload.status).to eq("approved")
      expect(attendance.reload.late_minutes).to eq(0)
      expect(AuditLog.where(auditable: req)).to be_empty
    end
  end

  # ── G. cancellation ────────────────────────────────────────────────────────
  describe "G. cancellation of an approved correction" do
    before do
      complete_rest_of_month!
      penalty_line("late_penalty", -100.0, 40)
      penalty_line("early_leave_penalty", -200.0, 120)
      entry.recalculate_totals!
    end

    it "restores punch and source from the snapshot, recomputes, RECREATES the deleted late line, audits, cancels" do
      req = correction("wrong_check_in_time", "09:00")
      approve(req)
      expect(line("late_penalty")).to be_nil

      result = cancel(req)

      expect(result).to be_success
      expect(attendance.reload).to have_attributes(check_in_at: at(9, 40), check_in_source: "device", late_minutes: 40)
      expect(line("late_penalty")).to have_attributes(amount: -100.0, original_minutes: 40,
                                                      description: "Late arrival #{day}")
      expect(line("early_leave_penalty")).to have_attributes(amount: -200.0, original_minutes: 120)
      expect(entry.reload.total_deductions).to eq(300.0)
      expect(req.reload).to have_attributes(status: "cancelled", cancelled_by_id: reviewer.id)
      expect(audits(req)).to eq(%w[approve cancel])
    end

    it "updates an existing line back to the original minutes" do
      req = correction("wrong_check_in_time", "09:20")
      approve(req)
      expect(line("late_penalty").original_minutes).to eq(20)

      cancel(req)
      expect(line("late_penalty")).to have_attributes(amount: -100.0, original_minutes: 40)
    end

    it "restores a check-out correction the same way (check_out_at and source)" do
      req = correction("wrong_check_out_time", "16:50")
      approve(req)
      expect(line("early_leave_penalty")).to be_nil

      cancel(req)
      expect(attendance.reload).to have_attributes(check_out_at: at(15, 0), check_out_source: "device", early_leave_minutes: 120)
      expect(line("early_leave_penalty")).to have_attributes(amount: -200.0, original_minutes: 120,
                                                             description: "Early leave #{day}")
    end

    %w[finalized paid].each do |status|
      it "#{status} period: refused with cannot_cancel_finalized; attendance stays corrected, payroll untouched, no cancel audit" do
        req = correction("wrong_check_in_time", "09:00")
        approve(req)
        period.update_column(:status, status)
        before = snapshot_state(req)

        result = cancel(req)
        expect(result.error).to eq(I18n.t("requests.errors.cannot_cancel_finalized"))
        expect(snapshot_state(req)).to eq(before)
        expect(audits(req)).to eq([ "approve" ])
      end
    end

    it "missing attendance record: refused with no_attendance_record, request stays approved" do
      req = correction("wrong_check_in_time", "09:00")
      approve(req)
      PayrollLineItem.where(source_type: "AttendanceRecord").delete_all
      attendance.delete

      result = cancel(req)
      expect(result.error).to eq(I18n.t("requests.errors.no_attendance_record"))
      expect(req.reload.status).to eq("approved")
      expect(audits(req)).to eq([ "approve" ])
    end

    it "missing payroll entry: attendance restored, request cancelled, nothing created" do
      req = correction("wrong_check_in_time", "09:00")
      approve(req)
      PayrollLineItem.delete_all
      PayrollEntry.delete_all

      expect { cancel(req) }.not_to change(PayrollLineItem, :count)
      expect(attendance.reload.check_in_at).to eq(at(9, 40))
      expect(req.reload.status).to eq("cancelled")
    end

    it "missing payroll period: attendance restored, request cancelled" do
      req = correction("wrong_check_in_time", "09:00")
      approve(req)
      PayrollLineItem.delete_all
      PayrollEntry.delete_all
      period.destroy!

      expect(cancel(req)).to be_success
      expect(attendance.reload.late_minutes).to eq(40)
    end

    it "a failure while restoring payroll is not rescued, and the cancel transaction rolls back (attendance not restored, no cancel audit)" do
      req = correction("wrong_check_in_time", "09:00")
      approve(req)
      before = snapshot_state(req)
      allow(Attendance::PenaltyCalculator).to receive(:calculate).and_raise(StandardError, "boom")

      expect { cancel(req) }.to raise_error(StandardError, "boom")
      expect(snapshot_state(req)).to eq(before)
      expect(audits(req)).to eq([ "approve" ])
    end
  end

  describe "G. cancellation — zero penalty after restore" do
    before { complete_rest_of_month! }

    it "restored minutes under the threshold delete an existing line" do
      attendance(check_in: at(9, 10), late: 10)
      penalty_line("late_penalty", -100.0, 10) # stale line on a 10-minute lateness
      req = correction("wrong_check_in_time", "09:50")
      approve(req)
      expect(line("late_penalty")).to have_attributes(amount: -100.0, original_minutes: 50)

      cancel(req)
      expect(attendance.reload.late_minutes).to eq(10)
      expect(line("late_penalty")).to be_nil
    end

    it "restored to no lateness at all deletes the line (raw minutes 0)" do
      attendance(check_in: at(9, 0), late: 0)
      penalty_line("late_penalty", -100.0, 0)
      req = correction("wrong_check_in_time", "09:30")
      approve(req)
      expect(line("late_penalty")).to have_attributes(original_minutes: 30)

      cancel(req)
      expect(line("late_penalty")).to be_nil
    end
  end

  # ── H. audit and snapshot data ─────────────────────────────────────────────
  describe "H. data the approval produces" do
    before { attendance }

    it "persists the snapshot and approved_punch_at on the Workforce request" do
      req = correction("wrong_check_in_time", "09:00")
      approve(req)

      expect(req.reload).to have_attributes(original_check_in_at: at(9, 40), original_check_out_at: at(15, 0),
                                            original_check_in_source: "device", original_check_out_source: "device",
                                            approved_punch_at: at(9, 0), reviewed_by_id: reviewer.id)
    end

    it "the approve audit carries request fields, the punch review and attendance-derived values" do
      req = correction("wrong_check_in_time", "09:00")
      approve(req, approved_at: "2026-06-08T09:05", response_note: "ok")

      log = AuditLog.find_by!(auditable: req, action: "approve")
      expect(log).to have_attributes(actor_id: reviewer.id)
      expect(log.metadata.keys).to contain_exactly("request_type", "correction_type", "approved_time", "proposed_time",
                                                   "response_note", "punch_review", "attendance_window")
      expect(log.metadata).to include("request_type" => "punch_correction", "correction_type" => "wrong_check_in_time",
                                      "proposed_time" => "09:00", "response_note" => "ok")
      expect(log.metadata["punch_review"]).to include("final_date" => "2026-06-08", "final_time" => "09:05",
                                                      "time_changed" => true, "date_changed" => false, "change" => "time",
                                                      "reviewer_id" => reviewer.id)
      expect(log.metadata["attendance_window"].keys)
        .to contain_exactly("final_punch_date", "final_punch_time", "effective_at", "inside_window",
                            "projected_worked_minutes", "duration_severity",
                            "confirmed_by_reviewer", "resulting_worked_minutes", "resulting_duration_severity")
      expect(log.metadata["attendance_window"]).to include(
        "final_punch_date" => "2026-06-08", "final_punch_time" => "09:05", "inside_window" => true,
        "projected_worked_minutes" => 355, "resulting_worked_minutes" => attendance.reload.worked_minutes,
        "duration_severity" => nil, "resulting_duration_severity" => nil, "confirmed_by_reviewer" => false
      )
      expect(attendance.worked_minutes).to eq(355) # 09:05 → 15:00
    end

    it "the cancel audit carries the reason and request type" do
      req = correction("wrong_check_in_time", "09:00")
      approve(req)
      cancel(req)

      log = AuditLog.find_by!(auditable: req, action: "cancel")
      expect(log.changes_json).to eq("status" => %w[approved cancelled])
      expect(log.metadata).to eq("reason" => "characterization", "request_type" => "punch_correction")
    end
  end

  # ── I. shared helpers ──────────────────────────────────────────────────────
  describe "I. helpers shared with / duplicated by Payroll::PermissionReverter" do
    let(:req) { correction("wrong_check_in_time", "09:00") }
    let(:canceller) { Requests::Canceller.new(request: req, cancelled_by: reviewer, reason: "x") }
    let(:reverter)  { Payroll::PermissionReverter.new(req) }

    before { attendance && entry }

    it "covering_period: both pick the request month's period regardless of status" do
      period.update_column(:status, "paid")
      expect(canceller.send(:covering_period)).to eq(period)
      expect(reverter.send(:covering_period)).to eq(period)
    end

    it "daily_rate_for and compute_penalty give identical results" do
      expect(canceller.send(:daily_rate_for, entry)).to eq(reverter.send(:daily_rate_for, entry))
      expect(canceller.send(:daily_rate_for, entry)).to eq(400)

      { "late_penalty" => [ 40, -100.0 ], "early_leave_penalty" => [ 120, -200.0 ] }.each do |type, (minutes, amount)|
        expect(canceller.send(:compute_penalty, attendance, 400, type, minutes)).to eq(amount)
        expect(reverter.send(:compute_penalty, attendance, 400, type, minutes)).to eq(amount)
      end
    end

    it "the approval applier differs: it only looks at OPEN periods, by the record's work date" do
      applier = Payroll::PunchCorrectionApplier.new(req, attendance)
      expect(applier.send(:open_period_covering, day)).to eq(period)

      period.update_column(:status, "finalized")
      expect(applier.send(:open_period_covering, day)).to be_nil
      expect(canceller.send(:covering_period)).to eq(period)
    end
  end
end
