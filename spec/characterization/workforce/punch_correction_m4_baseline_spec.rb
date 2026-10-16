require "rails_helper"

# Characterization (Pilot 10 — Punch Correction, M4-1) — the CURRENT behaviour
# the M4 ownership move must preserve or deliberately change, on top of M1
# (spec/characterization/workforce/punch_correction_effects_spec.rb, not repeated):
#
#   J. approve → cancel round trips (snapshot, attendance, payroll)
#   K. the persisted approved_punch_at, the written punch and the audit's
#      effective_at are the same minute-precision moment
#   L. refusal order and exact user-facing messages (approval and cancellation)
#   M. payroll-period lookup by status (draft / under_review /
#      branch_review_completed / finalized / paid / none)
#   N. existing-entry recalculation (patch + recalculate_totals!, never
#      Payroll::EntryRecalculator) and the no-entry case
#   O. preservation of overtime overrides, waivers, adjustments, cancelled
#      additions, advance / obligation deductions and permission minutes
#   P. payroll failures (RecordInvalid) roll the whole transaction back
#   Q. audit: attendance_window from the pre-write assessment, resulting_* from
#      the post-write record
#   R. locked-period protections (full state)
#   S. concurrency — recorded as `pending` known gaps in M4-1, fixed in M4-2
#      (request row lock + re-check). Each race is simulated deterministically
#      by a second, stale in-memory copy of the request (loaded before the
#      first operation commits) — exactly the check-then-act window two
#      concurrent requests have. The period-finalization races moved to the
#      two-connection spec/services/requests/punch_correction_period_lock_spec.rb.
#
# Examples that Decisions A / B / C (M4-3) are expected to change are marked
# "(changes with Decision A|B|C)".
RSpec.describe "Characterization: punch correction M4 baseline" do
  around { |ex| travel_to(Time.zone.local(2026, 7, 15, 12, 0, 0)) { ex.run } }

  let(:business) { create(:business, working_days_per_month: 22) } # Asia/Riyadh, daily rate 8,800 / 22 = 400
  let(:tz)       { ActiveSupport::TimeZone[business.timezone] }
  let(:branch)   { create(:branch, business: business) }
  let(:employee) { create(:user, business: business) }
  let(:reviewer) { create(:user, :owner, business: business) }
  let(:other_reviewer) { create(:user, business: business) } # services do not authorize; policies are pinned elsewhere
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

  # Default: 40 minutes late (09:40) and 120 minutes early (15:00), derived
  # fields recomputed so a round trip can be compared column by column.
  def attendance(check_in: at(9, 40), check_out: at(15, 0))
    @attendance ||= create(:attendance_record, user: employee, branch: branch, shift_assignment: assignment,
                                               date: day, work_date: day, check_in_at: check_in, check_out_at: check_out,
                                               check_in_source: "device", check_out_source: "device",
                                               status: "late").tap do |record|
      Attendance::RecordRecomputer.recompute!(record)
      record.save!
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

  # The penalty lines for the default record, totals settled, needs_review cleared.
  def standard_payroll
    penalty_line("late_penalty", -100.0, 40)
    penalty_line("early_leave_penalty", -200.0, 120)
    entry.recalculate_totals!
    entry.update_column(:needs_review, false)
  end

  def line(type) = entry.payroll_line_items.find_by(item_type: type, source_type: "AttendanceRecord", source_id: attendance.id)

  def correction(type, time, date: day, proposed_date: date)
    build(:employee_request, :punch_correction, :pending, user: employee, requested_for_date: date, correction_type: type,
                                                          proposed_time: time, proposed_date: proposed_date)
      .tap { |req| req.save!(validate: false) }
  end

  def approve(req, by: reviewer, **opts)
    Requests::Approver.approve(request: req, reviewed_by: by, confirm_out_of_window: true, **opts)
  end

  def cancel(req, by: reviewer) = Requests::Canceller.cancel(request: req, cancelled_by: by, reason: "characterization")
  def audits(req)               = AuditLog.where(auditable: req).order(:id).pluck(:action)
  def stale(req)                = EmployeeRequest.find(req.id) # a second, independently loaded copy

  def request_state(req)
    req.reload.attributes.slice(*%w[status approved_punch_at reviewed_by_id reviewed_at cancelled_by_id cancelled_at
                                    original_check_in_at original_check_out_at original_check_in_source
                                    original_check_out_source])
  end

  def record_state = attendance.reload.attributes.except("updated_at")
  def lines_state  = entry.payroll_line_items.reload.order(:id).map { |li| li.attributes.except("updated_at") }
  def entry_state  = entry.reload.attributes.except("updated_at")

  def full_state(req) = { request: request_state(req), record: record_state, lines: lines_state, entry: entry_state }

  # ── J. round trips ─────────────────────────────────────────────────────────
  describe "J. approve → cancel round trips" do
    before { standard_payroll }

    it "a line the correction updates: attendance, the line and the entry come back exactly; the snapshot stays on the request" do
      req           = correction("wrong_check_in_time", "09:20")
      record_before = record_state
      lines_before  = lines_state
      entry_before  = entry_state

      approve(req)
      expect(line("late_penalty")).to have_attributes(amount: -100.0, original_minutes: 20)
      cancel(req)

      expect(record_state).to eq(record_before)
      expect(lines_state).to eq(lines_before)
      expect(entry_state).to eq(entry_before)
      expect(req.reload).to have_attributes(status: "cancelled", approved_punch_at: at(9, 20),
                                            original_check_in_at: at(9, 40), original_check_out_at: at(15, 0),
                                            original_check_in_source: "device", original_check_out_source: "device")
    end

    it "a line the correction deletes is RECREATED with the same money but a new id, a generated description and nil permission_minutes; needs_review stays set" do
      req           = correction("wrong_check_in_time", "09:00")
      record_before = record_state
      late_before   = line("late_penalty").attributes
      totals        = %w[total_deductions net_salary total_overtime total_bonuses advances_deducted obligations_deducted]
      totals_before = entry.attributes.slice(*totals)

      approve(req)
      expect(line("late_penalty")).to be_nil
      expect(entry.reload.needs_review).to be(true)
      cancel(req)

      recreated = line("late_penalty")
      expect(record_state).to eq(record_before)
      expect(recreated.id).not_to eq(late_before["id"])
      expect(recreated.attributes.except("id", "created_at", "updated_at", "description", "permission_minutes"))
        .to eq(late_before.except("id", "created_at", "updated_at", "description", "permission_minutes"))
      expect(recreated).to have_attributes(description: "Late arrival #{day}", permission_minutes: nil)
      expect(late_before["permission_minutes"]).to eq(0)
      expect(entry.reload.attributes.slice(*totals)).to eq(totals_before)
      expect(entry.needs_review).to be(true) # set by the approval, never cleared by the cancellation
    end

    it "with a permission already applied to the line, the round trip does NOT restore the amount (changes with Decision B)" do
      create(:employee_request, :late_permission, status: "approved", user: employee, requested_for_date: day,
                                                  duration_minutes: 30, reviewed_by: reviewer)
      line("late_penalty").update!(permission_minutes: 30, amount: 0.0) # as PermissionApplier leaves it
      entry.recalculate_totals!
      req = correction("wrong_check_in_time", "09:35")

      approve(req)
      expect(line("late_penalty")).to have_attributes(amount: -100.0, original_minutes: 35, permission_minutes: 30)
      cancel(req)

      expect(line("late_penalty")).to have_attributes(amount: -100.0, original_minutes: 40, permission_minutes: 30)
      expect(attendance.reload.late_minutes).to eq(40)
    end
  end

  describe "J. round trips — missing punches (no payroll)" do
    it "a missing check-out: the snapshot keeps nil, the cancellation restores nil and re-derives the record" do
      attendance(check_out: nil)
      record_before = record_state
      expect(record_before).to include("check_out_at" => nil, "worked_minutes" => nil)
      req = correction("missing_check_out", "17:00")

      approve(req)
      expect(attendance.reload).to have_attributes(check_out_at: at(17, 0), check_out_source: "admin_manual")
      expect(req.reload).to have_attributes(original_check_in_at: at(9, 40), original_check_out_at: nil,
                                            original_check_out_source: "device")
      cancel(req)

      expect(record_state).to eq(record_before)
    end

    # attendance_records.check_in_at is NOT NULL (and validated), so a record
    # always carries a check-in: a missing_check_in correction replaces the punch
    # that is there, and its snapshot — the assessment's applied? — is never nil.
    it "a missing check-in: the record's existing check-in is snapshotted (never nil) and restored" do
      expect do # savepoint, so the aborted statement does not abort the example's transaction
        ActiveRecord::Base.transaction(requires_new: true) { attendance.update_columns(check_in_at: nil) }
      end.to raise_error(ActiveRecord::NotNullViolation)
      attendance.destroy!
      @attendance = nil
      attendance(check_in: at(12, 0)) # the punch the employee says is not their check-in
      record_before = record_state
      req = correction("missing_check_in", "09:40")

      approve(req)
      expect(req.reload).to have_attributes(original_check_in_at: at(12, 0), original_check_in_source: "device")
      expect(attendance.reload).to have_attributes(check_in_at: at(9, 40), check_in_source: "admin_manual")
      cancel(req)

      expect(record_state).to eq(record_before)
    end
  end

  # ── K. the effective moment ────────────────────────────────────────────────
  describe "K. persisted approved_punch_at == written punch == audit effective_at (minute precision)" do
    before { attendance }

    # Only the applier's own call (request: alone — the moment it writes, rebuilt
    # from the saved request); the assessment and the audit's punch_review pass
    # an explicit date / time.
    def written_moment_spy
      seen = []
      allow(Requests::PunchCorrectionApplier).to receive(:effective_punch_at).and_wrap_original do |original, **kwargs|
        original.call(**kwargs).tap { |moment| seen << moment if kwargs.keys == [ :request ] }
      end
      seen
    end

    it "a reviewer datetime string" do
      seen = written_moment_spy
      req  = correction("wrong_check_in_time", "09:00")
      approve(req, approved_at: "2026-06-08T09:05")

      audit_at = Time.iso8601(AuditLog.find_by!(auditable: req, action: "approve").metadata.dig("attendance_window", "effective_at"))
      expect(req.reload.approved_punch_at).to eq(at(9, 5))
      expect(attendance.reload.check_in_at).to eq(at(9, 5))
      expect(audit_at).to eq(at(9, 5))
      expect(seen).to eq([ at(9, 5) ]) # the moment the applier wrote, rebuilt from the saved request
    end

    it "a reviewer Time with seconds is truncated to the minute before it is persisted or written" do
      req = correction("wrong_check_in_time", "09:00")
      approve(req, approved_at: at(9, 5) + 42.seconds)

      expect(req.reload.approved_punch_at).to eq(at(9, 5))
      expect(attendance.reload.check_in_at).to eq(at(9, 5))
      expect(req.approved_punch_at.sec).to eq(0)
    end

    it "no reviewer choice: the employee's proposal" do
      req = correction("wrong_check_in_time", "09:10")
      approve(req)

      expect(req.reload.approved_punch_at).to eq(at(9, 10))
      expect(attendance.reload.check_in_at).to eq(at(9, 10))
    end

    it "an overnight check-out dated the next calendar day is written on that date" do
      req = correction("wrong_check_out_time", "17:00")
      approve(req, approved_at: "2026-06-09T02:00")

      expect(req.reload.approved_punch_at).to eq(at(2, 0, date: day + 1))
      expect(attendance.reload.check_out_at).to eq(at(2, 0, date: day + 1))
    end
  end

  # ── L. refusal order and messages ──────────────────────────────────────────
  describe "L. refusal order and exact messages" do
    let(:no_record_message) { "No attendance record found for 2026-06-08" } # hardcoded in Requests::PunchCorrectionApplier

    context "approval" do
      it "an unparseable reviewer datetime is refused first, before the attendance record is looked up" do
        period.update_column(:status, "finalized")
        result = approve(correction("wrong_check_in_time", "09:00"), approved_at: "garbage")
        expect(result.error).to eq(I18n.t("requests.errors.invalid_approved_date"))
        expect(result.error).to eq("The approved date & time is invalid.")
      end

      it "the punch order is refused before the payroll-lock check (it runs before the transaction)" do
        attendance
        period.update_column(:status, "finalized")
        req    = correction("wrong_check_out_time", "09:00") # before the 09:40 check-in
        result = approve(req)

        expect(result.error).to eq(I18n.t("requests.errors.check_out_not_after_check_in"))
        expect(result.error).to eq("The check-out time must be after the check-in time.")
        expect(req.reload.status).to eq("pending")
      end

      it "a check-in after the check-out is refused with check_out_before_check_in" do
        attendance
        result = approve(correction("wrong_check_in_time", "16:00"))
        expect(result.error).to eq(I18n.t("requests.errors.check_out_before_check_in"))
      end

      it "the confirmation gate is refused before the payroll-lock check" do
        attendance
        period.update_column(:status, "finalized")
        req    = correction("wrong_check_in_time", "20:00", proposed_date: day - 1) # the evening before: outside the window
        result = Requests::Approver.approve(request: req, reviewed_by: reviewer)

        expect(result.error).to eq(I18n.t("requests.errors.attendance_window_confirmation_required"))
      end

      it "no attendance record is refused before the payroll lock, with the hardcoded English message" do
        period.update_column(:status, "finalized")
        req    = correction("wrong_check_in_time", "09:00")
        result = approve(req)

        expect(result.error).to eq(no_record_message)
        expect(req.reload).to have_attributes(status: "pending", approved_punch_at: nil, original_check_in_at: nil)
        expect(audits(req)).to be_empty
      end

      it "the no-record message stays English under the Arabic locale" do
        req = correction("wrong_check_in_time", "09:00")
        I18n.with_locale(:ar) { expect(approve(req).error).to eq(no_record_message) }
      end

      it "a locked period comes last, with cannot_approve_finalized" do
        attendance
        period.update_column(:status, "paid")
        result = approve(correction("wrong_check_in_time", "09:00"))
        expect(result.error).to eq(I18n.t("requests.errors.cannot_approve_finalized"))
        expect(result.error)
          .to eq("This punch correction cannot be approved because the payroll period has already been finalized or paid.")
      end

      it "a request that is no longer pending is refused before anything else" do
        req = correction("wrong_check_in_time", "09:00")
        req.update_column(:status, "rejected")
        expect(approve(req).error).to eq("Request is already rejected")
      end
    end

    context "cancellation" do
      it "no attendance record is refused before the payroll lock, with the i18n message" do
        attendance
        req = correction("wrong_check_in_time", "09:00")
        approve(req)
        period.update_column(:status, "finalized")
        attendance.delete

        result = cancel(req)
        expect(result.error).to eq(I18n.t("requests.errors.no_attendance_record"))
        expect(result.error).to eq("No attendance record was found for this request date.")
        expect(req.reload.status).to eq("approved")
      end

      it "the no-record message is translated under the Arabic locale" do
        attendance
        req = correction("wrong_check_in_time", "09:00")
        approve(req)
        attendance.delete

        I18n.with_locale(:ar) do
          expect(cancel(req).error).to eq(I18n.t("requests.errors.no_attendance_record", locale: :ar))
        end
        expect(I18n.t("requests.errors.no_attendance_record", locale: :ar))
          .not_to eq(I18n.t("requests.errors.no_attendance_record", locale: :en))
      end

      it "an already-cancelled request and a rejected one are refused before any effect" do
        attendance
        cancelled = correction("wrong_check_in_time", "09:00").tap { |r| r.update_column(:status, "cancelled") }
        rejected  = correction("wrong_check_in_time", "09:05").tap { |r| r.update_column(:status, "rejected") }

        expect(cancel(cancelled).error).to eq(I18n.t("requests.errors.already_cancelled"))
        expect(cancel(rejected).error).to eq(I18n.t("requests.errors.cannot_cancel"))
      end

      it "a pending correction is cancelled without touching attendance or payroll" do
        standard_payroll
        req    = correction("wrong_check_in_time", "09:00")
        before = { record: record_state, lines: lines_state, entry: entry_state }

        expect(cancel(req)).to be_success
        expect({ record: record_state, lines: lines_state, entry: entry_state }).to eq(before)
        expect(audits(req)).to eq([ "cancel" ])
      end
    end
  end

  # ── M. payroll-period lookup ───────────────────────────────────────────────
  describe "M. payroll-period lookup (the request month's period, by status)" do
    before { standard_payroll }

    %w[draft under_review branch_review_completed].each do |status|
      it "#{status}: approval patches the line, cancellation restores it" do
        period.update_column(:status, status)
        req = correction("wrong_check_in_time", "09:20")

        expect(approve(req)).to be_success
        expect(line("late_penalty").original_minutes).to eq(20)
        expect(cancel(req)).to be_success
        expect(line("late_penalty").original_minutes).to eq(40)
      end
    end

    %w[finalized paid].each do |status|
      it "#{status}: approval refused and cancellation refused, nothing written" do
        req = correction("wrong_check_in_time", "09:20")
        period.update_column(:status, status)
        before = full_state(req)

        expect(approve(req).error).to eq(I18n.t("requests.errors.cannot_approve_finalized"))
        expect(full_state(req)).to eq(before)
        expect(audits(req)).to be_empty
      end
    end

    it "a period of another month only: attendance corrected, that period's entry untouched" do
      PayrollLineItem.delete_all
      PayrollEntry.delete_all
      period.destroy!
      july       = create(:payroll_period, business: business, period_year: 2026, period_month: 7, working_days: 22)
      july_entry = create(:payroll_entry, payroll_period: july, user: employee, base_salary: 8_800, net_salary: 8_500)
      before     = july_entry.attributes.except("updated_at")

      req = correction("wrong_check_in_time", "09:00")
      expect(approve(req)).to be_success
      expect(cancel(req)).to be_success
      expect(july_entry.reload.attributes.except("updated_at")).to eq(before)
    end

    it "another business's period for the same month is never used" do
      PayrollLineItem.delete_all
      PayrollEntry.delete_all
      period.destroy!
      create(:payroll_period, business: create(:business), period_year: 2026, period_month: 6, working_days: 22,
                              status: "finalized")

      expect(approve(correction("wrong_check_in_time", "09:00"))).to be_success
    end
  end

  # ── N. existing-entry recalculation ────────────────────────────────────────
  describe "N. existing-entry recalculation and the no-entry case" do
    it "neither approval nor cancellation calls Payroll::EntryRecalculator or Payroll::EntryCalculator (changes with Decision C)" do
      standard_payroll
      expect(Payroll::EntryRecalculator).not_to receive(:call)
      expect(Payroll::EntryCalculator).not_to receive(:call)

      req = correction("wrong_check_in_time", "09:00")
      approve(req)
      cancel(req)
    end

    it "an entry without penalty lines still has its totals recalculated (a stale net salary is corrected)" do
      attendance
      entry(net_salary: 8_500) # stale: no line items, base 8,800
      req = correction("wrong_check_in_time", "09:00")

      approve(req)
      expect(entry.reload).to have_attributes(net_salary: 8_800.0, total_deductions: 0)
      expect(entry.payroll_line_items).to be_empty
    end

    it "another employee's entry in the same period is untouched" do
      standard_payroll
      colleague = create(:user, business: business)
      other     = create(:payroll_entry, payroll_period: period, user: colleague, base_salary: 5_000, net_salary: 4_000)
      create(:payroll_line_item, :late_penalty, payroll_entry: other, review_status: "approved",
                                                source_type: "AttendanceRecord", source_id: attendance.id, original_minutes: 40)
      before = [ other.attributes.except("updated_at"), other.payroll_line_items.map(&:attributes) ]

      req = correction("wrong_check_in_time", "09:00")
      approve(req)
      cancel(req)

      expect([ other.reload.attributes.except("updated_at"), other.payroll_line_items.reload.map(&:attributes) ]).to eq(before)
    end

    it "no entry: a full round trip creates no entry and no line" do
      attendance
      period
      req = correction("wrong_check_in_time", "09:00")

      expect { approve(req) }.not_to change { [ PayrollEntry.count, PayrollLineItem.count ] }
      expect { cancel(req) }.not_to change { [ PayrollEntry.count, PayrollLineItem.count ] }
      expect(attendance.reload.late_minutes).to eq(40)
    end
  end

  # ── O. preservation of other payroll decisions ─────────────────────────────
  describe "O. preservation of the entry's other payroll data" do
    let(:obligation) do
      create(:employee_obligation, business: business, user: employee, total_amount: 3_000, remaining_amount: 2_500,
                                   installment_amount: 500)
    end
    let(:adjustment) do
      create(:payroll_adjustment, :manual_deduction, payroll_period: period, user: employee, amount: 50.0,
                                                     review_status: :approved)
    end

    before do
      standard_payroll
      create(:payroll_line_item, :overtime, payroll_entry: entry, amount: 300.0)
      create(:payroll_line_item, :manual_deduction, payroll_entry: entry, amount: -50.0, source_id: adjustment.id)
      create(:payroll_line_item, :manual_deduction, :deduction_waived, payroll_entry: entry, amount: -100.0)
      create(:payroll_line_item, :cash_incentive, :addition_cancelled, payroll_entry: entry, amount: 200.0)
      create(:payroll_line_item, :commission, payroll_entry: entry, amount: 100.0)
      create(:payroll_line_item, :advance_deduction, payroll_entry: entry, amount: -300.0)
      create(:payroll_line_item, payroll_entry: entry, item_type: "obligation_deduction", amount: -500.0,
                                 review_status: "approved", source_type: "EmployeeObligation", source_id: obligation.id)
      create(:obligation_deduction, employee_obligation: obligation, payroll_period: period, deducted_amount: 500,
                                    remaining_before: 3_000, remaining_after: 2_500)
      entry.update!(overtime_override_mode: "amount", approved_overtime_pay: 150.0, overtime_override_reason: "capped",
                    overtime_overridden_by_id: reviewer.id, overtime_overridden_at: Time.current)
      entry.recalculate_totals!
    end

    def other_lines = entry.payroll_line_items.reload.where.not(item_type: %w[late_penalty early_leave_penalty])
                           .order(:id).map(&:attributes)

    def preserved
      { lines:       other_lines,
        override:    entry.reload.attributes.slice(*%w[overtime_override_mode approved_overtime_pay approved_overtime_minutes
                                                       overtime_override_reason overtime_overridden_by_id
                                                       overtime_overridden_at overtime_override_stale]),
        deductions:  ObligationDeduction.order(:id).map(&:attributes),
        obligation:  obligation.reload.attributes.except("updated_at"),
        adjustment:  adjustment.reload.attributes.except("updated_at") }
    end

    def totals = entry.reload.attributes.slice(*%w[total_deductions total_overtime total_bonuses advances_deducted
                                                   obligations_deducted net_salary])

    it "approval and cancellation leave every other line, the override, the obligation snapshot and the adjustment untouched" do
      before_totals = totals
      expect(before_totals).to eq("total_deductions" => 350.0, "total_overtime" => 150.0, "total_bonuses" => 100.0,
                                  "advances_deducted" => 300.0, "obligations_deducted" => 500.0, "net_salary" => 7_900.0)
      before = preserved
      req    = correction("wrong_check_in_time", "09:00")

      approve(req)
      expect(preserved).to eq(before)
      expect(totals).to include("total_deductions" => 250.0, "net_salary" => 8_000.0) # late line deleted; waived / cancelled stay out

      cancel(req)
      expect(preserved).to eq(before)
      expect(totals).to eq(before_totals)
    end

    it "permission minutes on the other penalty line are kept untouched" do
      line("early_leave_penalty").update!(permission_minutes: 30)
      approve(correction("wrong_check_in_time", "09:00"))
      expect(line("early_leave_penalty")).to have_attributes(permission_minutes: 30, amount: -200.0, original_minutes: 120)
    end
  end

  # ── P. payroll failure rollback ────────────────────────────────────────────
  describe "P. a payroll RecordInvalid rolls the whole transaction back" do
    before { standard_payroll }

    def invalid_payroll!
      invalid = PayrollEntry.new.tap { |e| e.errors.add(:base, "payroll invalid") }
      allow_any_instance_of(PayrollEntry).to receive(:recalculate_totals!).and_raise(ActiveRecord::RecordInvalid.new(invalid))
    end

    it "approval: a failed result with the record's messages; request, snapshot, attendance and payroll unchanged; no audit" do
      req    = correction("wrong_check_in_time", "09:00")
      before = full_state(req)
      invalid_payroll!

      result = approve(req)
      expect(result).not_to be_success
      expect(result.error).to eq("payroll invalid")
      expect(full_state(req)).to eq(before)
      expect(audits(req)).to be_empty
    end

    it "cancellation: a failed result with the record's messages (not raised); request stays approved, attendance not restored; no cancel audit" do
      req = correction("wrong_check_in_time", "09:00")
      approve(req)
      before = full_state(req)
      invalid_payroll!

      result = cancel(req)
      expect(result).not_to be_success
      expect(result.error).to eq("payroll invalid")
      expect(full_state(req)).to eq(before)
      expect(audits(req)).to eq([ "approve" ])
    end
  end

  # ── Q. audit sources ───────────────────────────────────────────────────────
  describe "Q. audit: attendance_window from the pre-write assessment, resulting_* from the saved record" do
    before { attendance }

    it "resulting_worked_minutes / resulting_duration_severity come from the saved record, the rest from the assessment" do
      allow(Attendance::RecordRecomputer).to receive(:recompute!).and_wrap_original do |original, record|
        original.call(record).tap { record.worked_minutes += 7 if record.persisted? } # only the real write
      end
      allow_any_instance_of(AttendanceRecord).to receive(:duration_severity).and_return(:critical)

      req = correction("wrong_check_in_time", "09:05")
      approve(req)

      window = AuditLog.find_by!(auditable: req, action: "approve").metadata["attendance_window"]
      expect(window).to include("projected_worked_minutes" => 355, "duration_severity" => nil, "inside_window" => true,
                                "resulting_worked_minutes" => 362, "resulting_duration_severity" => "critical")
      expect(attendance.reload.worked_minutes).to eq(362)
    end

    it "the facts are read once, outside the approval transaction, before anything is written" do
      events = []
      depth  = -> { ActiveRecord::Base.connection.open_transactions }
      allow(Requests::PunchCorrectionEffects).to receive(:correction_facts).and_wrap_original do |original, **kwargs|
        events << [ :facts, depth.call ]
        original.call(**kwargs)
      end
      allow(Requests::PunchCorrectionApplier).to receive(:call).and_wrap_original do |original, **kwargs|
        events << [ :applier, depth.call ]
        original.call(**kwargs)
      end
      baseline = depth.call

      approve(correction("wrong_check_in_time", "09:00"))

      expect(events.map(&:first)).to eq(%i[facts applier])
      expect(events.first.last).to eq(baseline)
      expect(events.last.last).to be > baseline
    end
  end

  # ── R. locked periods ──────────────────────────────────────────────────────
  describe "R. locked periods (full state)" do
    before { standard_payroll }

    %w[finalized paid].each do |status|
      it "#{status}: approval writes nothing anywhere (request, snapshot, attendance, lines, entry, audit)" do
        req = correction("wrong_check_in_time", "09:00")
        period.update_column(:status, status)
        before = full_state(req)

        approve(req)
        expect(full_state(req)).to eq(before)
        expect(audits(req)).to be_empty
      end

      it "#{status} after approval: cancellation writes nothing anywhere and keeps the request approved" do
        req = correction("wrong_check_in_time", "09:00")
        approve(req)
        period.update_column(:status, status)
        before = full_state(req)

        expect(cancel(req).error).to eq(I18n.t("requests.errors.cannot_cancel_finalized"))
        expect(full_state(req)).to eq(before)
        expect(audits(req)).to eq([ "approve" ])
      end
    end
  end

  # ── S. concurrency (fixed in M4-2) ─────────────────────────────────────────
  describe "S. concurrency — the request row is locked and its state re-checked (M4-2)" do
    before { standard_payroll }

    it "two simultaneous approvals: the second must be refused and must not overwrite the snapshot" do
      req   = correction("wrong_check_in_time", "09:00")
      other = stale(req) # loaded while still pending, as by a second reviewer
      expect(approve(req)).to be_success

      second = approve(other, by: other_reviewer, approved_at: "2026-06-08T09:10")

      expect(second).not_to be_success
      expect(second.error).to eq("Request is already approved")
      expect(req.reload).to have_attributes(approved_punch_at: at(9, 0), reviewed_by_id: reviewer.id,
                                            original_check_in_at: at(9, 40), original_check_in_source: "device")
      expect(attendance.reload.check_in_at).to eq(at(9, 0))
      expect(audits(req)).to eq([ "approve" ])
    end

    it "two simultaneous cancellations: the second must be refused (no second effect, no second audit)" do
      req = correction("wrong_check_in_time", "09:00")
      approve(req)
      first, second = stale(req), stale(req) # both loaded while approved
      expect(cancel(first)).to be_success
      after_first = full_state(req)

      second_result = cancel(second, by: other_reviewer)

      expect(second_result.error).to eq(I18n.t("requests.errors.already_cancelled"))
      expect(full_state(req)).to eq(after_first)
      expect(audits(req)).to eq(%w[approve cancel])
    end

    it "cancellation of the pending request wins, then the approval: the approval must be refused" do
      req      = correction("wrong_check_in_time", "09:00")
      approver = stale(req) # loaded while pending
      expect(cancel(req)).to be_success

      result = approve(approver)

      expect(result).not_to be_success
      expect(result.error).to eq("Request is already cancelled")
      expect(req.reload.status).to eq("cancelled")
      expect(attendance.reload.check_in_at).to eq(at(9, 40))
      expect(line("late_penalty")).to have_attributes(amount: -100.0, original_minutes: 40)
      expect(audits(req)).to eq([ "cancel" ])
    end

    it "approval wins, then a cancellation loaded while pending: it must not leave a cancelled request with an applied correction" do
      req       = correction("wrong_check_in_time", "09:00")
      canceller = stale(req) # loaded while pending
      expect(approve(req)).to be_success

      result = cancel(canceller)

      cancelled_with_effect = req.reload.cancelled? && attendance.reload.check_in_at == at(9, 0)
      expect(cancelled_with_effect).to be(false)
      # Refused: who may cancel depends on the status (an employee may cancel only
      # a pending request), and the caller acted on "pending".
      expect(result.error).to eq(I18n.t("requests.errors.cannot_cancel"))
      expect(req.status).to eq("approved")
      expect(audits(req)).to eq([ "approve" ])
    end

    # Period-finalization races need a second database connection (one connection
    # never blocks itself): spec/services/requests/punch_correction_period_lock_spec.rb.
  end
end
