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

  # Complete, on-time attendance on June's other 21 working days, so the entry's
  # full recalculation (Decision C, M4-3) derives exactly the hand-built entry:
  # 22 days worked, no absence, base 8,800, only the corrected day's penalties.
  def complete_rest_of_month!
    (Date.new(2026, 6, 1)..Date.new(2026, 6, 30)).select { |d| d.on_weekday? && d != day }.each do |d|
      create(:attendance_record, user: employee, branch: branch, shift_assignment: assignment, date: d, work_date: d,
                                 check_in_at: at(9, 0, date: d), check_out_at: at(17, 0, date: d),
                                 check_in_source: "device", check_out_source: "device", status: "present")
        .tap { |record| Attendance::RecordRecomputer.recompute!(record) && record.save! }
    end
  end

  # The employee's June entry as payroll generation derives it (M4-3: built by
  # Payroll::EntryCalculator, not by hand, so a recalculation starts from a real
  # derivation): base 8,800, late −100 (40 min), early −200 (120 min), net 8,500.
  def standard_payroll
    complete_rest_of_month!
    attendance
    @entry = Payroll::EntryCalculator.call(period: period, user: employee, business: business)
    @entry.update_column(:needs_review, false)
  end

  # Line content without row identity: a full recalculation (M4-3) destroys and
  # recreates every line item, so ids / timestamps never survive it.
  def line_contents
    entry.payroll_line_items.reload.map { |li| li.attributes.except("id", "created_at", "updated_at") }
         .sort_by { |attrs| [ attrs["item_type"], attrs["source_type"].to_s, attrs["source_id"].to_i ] }
  end

  def totals = entry.reload.attributes.slice(*%w[base_salary days_worked total_deductions total_overtime total_bonuses
                                                 advances_deducted obligations_deducted net_salary])

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

    # CHANGED in M4-3 (Decision C): the entry is re-derived on approval and on
    # cancellation, which recreates every line row, so the round trip restores
    # line CONTENT and the entry's figures, not row ids (until M4-2 the patched
    # rows kept their ids).
    it "a line the correction updates: attendance, the line content and the entry come back exactly; the snapshot stays on the request" do
      req           = correction("wrong_check_in_time", "09:20")
      record_before = record_state
      lines_before  = line_contents
      totals_before = totals

      approve(req)
      expect(line("late_penalty")).to have_attributes(amount: -100.0, original_minutes: 20)
      cancel(req)

      expect(record_state).to eq(record_before)
      expect(line_contents).to eq(lines_before)
      expect(totals).to eq(totals_before)
      expect(entry.needs_review).to be(false) # the figures never changed
      expect(req.reload).to have_attributes(status: "cancelled", approved_punch_at: at(9, 20),
                                            original_check_in_at: at(9, 40), original_check_out_at: at(15, 0),
                                            original_check_in_source: "device", original_check_out_source: "device")
    end

    # CHANGED in M4-3 (Decision C): the deleted line is recreated by the same
    # derivation that built it, so it comes back identical except for its row
    # (until M4-2 the canceller's copy had a generated description and nil
    # permission_minutes instead of the generated line's 0).
    it "a line the correction deletes is recreated identical but for its row; needs_review stays set" do
      req           = correction("wrong_check_in_time", "09:00")
      record_before = record_state
      late_before   = line("late_penalty").attributes
      totals_before = totals

      approve(req)
      expect(line("late_penalty")).to be_nil
      expect(entry.reload.needs_review).to be(true)
      cancel(req)

      recreated = line("late_penalty")
      expect(record_state).to eq(record_before)
      expect(recreated.id).not_to eq(late_before["id"])
      expect(recreated.attributes.except("id", "created_at", "updated_at"))
        .to eq(late_before.except("id", "created_at", "updated_at"))
      expect(recreated).to have_attributes(description: "Late arrival #{day}", permission_minutes: 0)
      expect(totals).to eq(totals_before)
      expect(entry.needs_review).to be(true) # set by the approval, never cleared by the cancellation
    end
  end

  # CHANGED in M4-3 (Decision B). Until M4-2 the approval ignored the approved
  # permission (the line was recomputed from the full minutes) and the round
  # trip did not restore the amount. The recalculation applies the permission
  # every time, so the round trip is exact.
  describe "J. round trips with and without an approved permission (Decision B)" do
    before do
      create(:employee_request, :late_permission, status: "approved", user: employee, requested_for_date: day,
                                                  duration_minutes: 20, reviewed_by: reviewer)
      standard_payroll # 40 late − 20 permitted = 20 minutes penalised → −100
    end

    it "the permission is applied before, during and after the correction, and the round trip is exact" do
      expect(line("late_penalty")).to have_attributes(amount: -100.0, original_minutes: 40, permission_minutes: 20)
      lines_before  = line_contents
      totals_before = totals
      req = correction("wrong_check_in_time", "09:30")

      approve(req) # 30 late − 20 permitted = 10 minutes, under the threshold
      expect(line("late_penalty")).to be_nil
      expect(totals).to include("total_deductions" => 200.0, "net_salary" => 8_600.0)

      cancel(req)
      expect(line_contents).to eq(lines_before)
      expect(totals).to eq(totals_before)
    end

    it "a correction the permission does not cover keeps the remainder penalised" do
      approve(correction("wrong_check_in_time", "10:00")) # 60 late − 20 permitted = 40 minutes
      expect(line("late_penalty")).to have_attributes(amount: -100.0, original_minutes: 60, permission_minutes: 20)
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
    # CHANGED in M4-3 (Decision C). Until M4-2 neither path used the standard
    # recalculation; now each recalculates the existing entry exactly once, for
    # the request's period, on behalf of the reviewer / canceller.
    it "approval and cancellation each recalculate the existing entry once, for the period, triggered by the actor" do
      standard_payroll
      canceller = other_reviewer
      allow(Payroll::EntryRecalculator).to receive(:call).and_call_original
      allow(Payroll::EntryCalculator).to receive(:call).and_call_original

      req = correction("wrong_check_in_time", "09:00")
      approve(req)
      expect(Payroll::EntryRecalculator).to have_received(:call).once
        .with(user: employee, period: period, triggered_by: reviewer)
      cancel(req, by: canceller)

      expect(Payroll::EntryRecalculator).to have_received(:call).twice
      expect(Payroll::EntryRecalculator).to have_received(:call).with(user: employee, period: period, triggered_by: canceller)
      expect(Payroll::EntryCalculator).to have_received(:call).twice.with(hash_including(entry: entry)) # never entry: nil
    end

    # CHANGED in M4-3 (Decisions A / C). Until M4-2 an entry without lines only
    # had its totals recomputed from its (absent) lines. It is now re-derived from
    # attendance: the early-leave line the day requires is created and the
    # stale figures are replaced.
    it "a stale entry without lines is re-derived from attendance: missing lines created, figures corrected" do
      complete_rest_of_month!
      attendance
      entry(net_salary: 1_234, days_worked: 3, total_deductions: 0) # stale, no line items
      approve(correction("wrong_check_in_time", "09:00"))

      expect(line("early_leave_penalty")).to have_attributes(amount: -200.0, original_minutes: 120)
      expect(line("late_penalty")).to be_nil
      expect(entry.reload).to have_attributes(days_worked: 22, base_salary: 8_800.0, total_deductions: 200.0,
                                              net_salary: 8_600.0)
    end

    it "the entry row is locked (after the period) before it is recalculated" do
      standard_payroll
      locks = []
      allow(PayrollEntry).to receive(:lock).and_wrap_original do |original, *args|
        locks << :entry
        original.call(*args)
      end
      allow(PayrollPeriod).to receive(:lock).and_wrap_original do |original, *args|
        locks << :period
        original.call(*args)
      end
      allow(Payroll::EntryRecalculator).to receive(:call).and_wrap_original do |original, **kwargs|
        locks << :recalculate
        original.call(**kwargs)
      end

      approve(correction("wrong_check_in_time", "09:00"))
      expect(locks).to eq(%i[period entry recalculate])
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
  # CHANGED in M4-3 (Decision C). Until M4-2 the correction patched only the
  # penalty lines, so ANY other row of the entry — even one with no payroll
  # source — stayed untouched. The entry is now re-derived from its sources, as
  # every attendance edit does: lines come back from attendance, approved
  # adjustments, active advances and due obligations (new rows), and the
  # management decisions on them (overtime override, deduction waiver, addition
  # cancellation) are re-applied by EntryRecalculator. This group therefore
  # builds the entry from real sources, generated by Payroll::EntryCalculator.
  describe "O. preservation of the entry's other payroll data (real sources)" do
    let(:overtime_day) { Date.new(2026, 6, 9) }
    let(:obligation) do
      create(:employee_obligation, business: business, user: employee, total_amount: 3_000, remaining_amount: 3_000,
                                   installment_amount: 500, start_month: 6, start_year: 2026)
    end
    let(:advance) do
      create(:advance, user: employee, total_amount: 300.0, remaining_amount: 300.0, issued_at: Date.new(2026, 6, 1))
    end

    def adjustment(trait, amount, reason)
      create(:payroll_adjustment, trait, payroll_period: period, user: employee, amount: amount, reason: reason,
                                         review_status: :approved)
    end

    def line_for(source) = entry.payroll_line_items.find_by(source_type: source.class.name, source_id: source.id)

    before do
      complete_rest_of_month!
      AttendanceRecord.find_by(user: employee, work_date: overtime_day).tap do |record| # two hours' overtime
        record.update!(check_out_at: at(19, 0, date: overtime_day))
        Attendance::RecordRecomputer.recompute!(record) && record.save!
      end
      @kept      = adjustment(:manual_deduction, 50.0, "Damaged uniform")
      @waived    = adjustment(:manual_deduction, 100.0, "Late report")
      @cancelled = adjustment(:cash_incentive, 200.0, "Weekend cover")
      @commission = adjustment(:commission, 100.0, "Sales")
      obligation
      advance
      attendance
      @entry = Payroll::EntryCalculator.call(period: period, user: employee, business: business)

      line_for(@waived).update!(deduction_waived: true, deduction_waiver_reason: "goodwill",
                                deduction_waived_by_id: reviewer.id, deduction_waived_at: Time.current)
      line_for(@cancelled).update!(addition_cancelled: true, addition_cancellation_reason: "duplicate",
                                   addition_cancelled_by_id: reviewer.id, addition_cancelled_at: Time.current)
      overtime_pay = entry.reload.calculated_overtime_pay
      entry.update!(overtime_override_mode: "amount", approved_overtime_pay: (overtime_pay / 2).round(2),
                    overtime_override_reason: "capped", overtime_overridden_by_id: reviewer.id,
                    overtime_overridden_at: Time.current)
      entry.recalculate_totals!
      entry.update_column(:needs_review, false)
    end

    # The decisions and source-derived values that must survive a recalculation.
    def decisions
      { override:   entry.reload.attributes.slice(*%w[overtime_override_mode approved_overtime_pay overtime_override_reason
                                                      overtime_overridden_by_id overtime_overridden_at
                                                      overtime_override_stale calculated_overtime_pay]),
        waiver:     line_for(@waived).attributes.slice(*%w[amount deduction_waived deduction_waiver_reason
                                                           deduction_waived_by_id deduction_waived_at]),
        cancelled:  line_for(@cancelled).attributes.slice(*%w[amount addition_cancelled addition_cancellation_reason
                                                              addition_cancelled_by_id addition_cancelled_at]),
        kept:       line_for(@kept).attributes.slice(*%w[amount deduction_waived review_status]),
        commission: line_for(@commission).attributes.slice(*%w[amount addition_cancelled]),
        advance:    line_for(advance).attributes.slice(*%w[amount]),
        overtime:   entry.payroll_line_items.overtime.map { |li| li.attributes.slice("amount", "source_id") },
        obligation: obligation.reload.remaining_amount,
        snapshots:  ObligationDeduction.where(payroll_period: period)
                                       .map { |od| od.attributes.slice("deducted_amount", "remaining_before", "remaining_after") },
        obligation_line: entry.payroll_line_items.obligation_deduction.map { |li| li.attributes.slice("amount") },
        adjustments: PayrollAdjustment.order(:id).map { |a| a.attributes.except("updated_at") } }
    end

    it "approval and cancellation re-derive the entry, re-apply every management decision and keep the sources intact" do
      before_decisions = decisions
      before_totals    = totals
      expect(before_decisions[:override]["overtime_override_mode"]).to eq("amount")
      expect(before_decisions[:snapshots]).to eq([ { "deducted_amount" => 500.0, "remaining_before" => 3_000.0,
                                                     "remaining_after" => 2_500.0 } ])
      expect(before_decisions[:obligation]).to eq(2_500.0)
      req = correction("wrong_check_in_time", "09:00")

      approve(req)
      expect(decisions).to eq(before_decisions)
      expect(line("late_penalty")).to be_nil
      expect(totals).to eq(before_totals.merge("total_deductions" => before_totals["total_deductions"] - 100,
                                               "net_salary"       => before_totals["net_salary"] + 100))

      cancel(req)
      expect(decisions).to eq(before_decisions)
      expect(totals).to eq(before_totals)
    end

    it "approved permission minutes on the other penalty line are applied from the permission, not the stored line" do
      create(:employee_request, :early_leave, status: "approved", user: employee, requested_for_date: day,
                                              duration_minutes: 60, reviewed_by: reviewer)
      approve(correction("wrong_check_in_time", "09:00")) # 120 early − 60 permitted = 60 minutes → still −200
      expect(line("early_leave_penalty")).to have_attributes(permission_minutes: 60, amount: -200.0, original_minutes: 120)
    end
  end

  # ── P. payroll failure rollback ────────────────────────────────────────────
  describe "P. a payroll RecordInvalid rolls the whole transaction back" do
    before { standard_payroll }

    # The payroll effect is Payroll::EntryRecalculator since M4-3 (until M4-2:
    # PayrollEntry#recalculate_totals! after the line patch).
    def invalid_payroll!
      invalid = PayrollEntry.new.tap { |e| e.errors.add(:base, "payroll invalid") }
      allow(Payroll::EntryRecalculator).to receive(:call).and_raise(ActiveRecord::RecordInvalid.new(invalid))
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

    # M4-3: the recalculation is never rescued and swallowed (unlike the
    # after-commit recalculation of AdjustmentService / ManualEntryService).
    it "a recalculation that fails mid-way (after rebuilding lines) rolls approval and cancellation back completely" do
      req    = correction("wrong_check_in_time", "09:00")
      before = full_state(req)
      allow(Payroll::EntryRecalculator).to receive(:call).and_wrap_original do |original, **kwargs|
        original.call(**kwargs)
        raise "recalculation boom" # after the entry and its lines were rewritten
      end

      expect(approve(req).error).to eq("recalculation boom")
      expect(full_state(req)).to eq(before)
      expect(audits(req)).to be_empty

      allow(Payroll::EntryRecalculator).to receive(:call).and_call_original
      approve(req)
      before = full_state(req)
      allow(Payroll::EntryRecalculator).to receive(:call).and_wrap_original do |original, **kwargs|
        original.call(**kwargs)
        raise "recalculation boom"
      end

      expect { cancel(req) }.to raise_error(RuntimeError, "recalculation boom") # cancellation never rescues it
      expect(full_state(req)).to eq(before)
      expect(audits(req)).to eq([ "approve" ])
    end

    it "a recalculation result that is not ok is raised, never ignored" do
      req    = correction("wrong_check_in_time", "09:00")
      before = full_state(req)
      allow(Payroll::EntryRecalculator).to receive(:call)
        .and_return(Payroll::EntryRecalculator::Result.new(ok: false, error: "no salary profile"))

      expect(approve(req).error).to eq("no salary profile")
      expect(full_state(req)).to eq(before)
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
