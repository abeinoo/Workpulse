module Attendance
  # Attendance & Payroll implementation of the Workforce
  # Requests::PunchCorrectionEffects contract (registered in
  # config/initializers/request_punch_correction_effects.rb):
  #
  #   correction_facts     → the attendance window (Attendance::PunchWindow), the
  #                          record's projected recomputation (RecordRecomputer on
  #                          an unsaved copy) and Attendance::DurationCheck; read by
  #                          Requests::PunchCorrectionAssessment since M3
  #   correction_approved  → the punch write and recomputation (moved from
  #                          Requests::PunchCorrectionApplier in M4-2), then the
  #                          entry's full recalculation (M4-3)
  #   correction_cancelled → the restore from the snapshot and recomputation
  #                          (moved from Requests::Canceller in M4-2), then the
  #                          entry's full recalculation (M4-3)
  #
  # Both write operations run inside the caller's transaction, after Workforce
  # has locked the request row. They look the payroll period of the request's
  # month up with a row lock (FOR UPDATE) before checking it, so Payroll::Approver
  # — which locks the same row before finalizing or paying — can neither finalize
  # the period between this check and the write nor be overtaken by it. Every
  # refusal is decided before anything is written. The payroll effect is the
  # standard recalculation (Decisions A / B / C, M4-3; see #recalculate_payroll).
  #
  # Calls nothing in Workforce.
  module PunchCorrectionEffects
    module_function

    def correction_facts(request:, field:, effective_at:, baseline: nil)
      contract = Requests::PunchCorrectionEffects
      window   = Attendance::PunchWindow.for(user: request.user, work_date: request.requested_for_date)
      record   = AttendanceRecord.find_by(user: request.user, work_date: request.requested_for_date)

      check_in_at  = baseline ? baseline.check_in_at  : record&.check_in_at
      check_out_at = baseline ? baseline.check_out_at : record&.check_out_at
      projected    = projected_worked_minutes(record, field, effective_at, check_in_at, check_out_at)

      contract::Facts.new(
        record_found:             !record.nil?, # not present? — the status enum defines it
        check_in_at:              check_in_at,
        check_out_at:             check_out_at,
        inside_window:            window.cover?(effective_at),
        shift_name:               window.shift&.name,
        shift_required_hours:     window.shift&.required_hours,
        shift_starts_at:          window.shift_starts_at,
        shift_ends_at:            window.shift_ends_at,
        projected_worked_minutes: projected,
        duration_severity:        Attendance::DurationCheck.severity(projected, business: request.user.business)
      )
    end

    # Refusals, in order: no attendance record; the request month's payroll
    # period finalized / paid; the corrected punches out of order.
    def correction_approved(request:, field:, effective_at:, actor:)
      contract = Requests::PunchCorrectionEffects
      record   = record_for(request)
      return contract::Approval.new(status: :no_attendance_record) unless record

      period = locked_period_for(request)
      return contract::Approval.new(status: :payroll_locked) if period&.locked?

      snapshot = contract::Snapshot.new(
        check_in_at:      record.check_in_at,
        check_out_at:     record.check_out_at,
        check_in_source:  record.check_in_source,
        check_out_source: record.check_out_source
      )

      # The date is applied exactly as selected; a check-out before the check-in
      # is refused rather than moved to another day. A check-out correction must
      # land strictly after the check-in (full datetime, so a next-day overnight
      # check-out is valid).
      check_in_at  = field == :check_in  ? effective_at : record.check_in_at
      check_out_at = field == :check_out ? effective_at : record.check_out_at
      if check_in_at && check_out_at
        return contract::Approval.new(status: :check_out_not_after_check_in) if field == :check_out && check_out_at <= check_in_at
        return contract::Approval.new(status: :check_out_before_check_in) if check_out_at < check_in_at
      end

      if field == :check_in
        record.check_in_at     = effective_at
        record.check_in_source = "admin_manual"
      else
        record.check_out_at     = effective_at
        record.check_out_source = "admin_manual"
      end
      record.save!
      Attendance::RecordRecomputer.recompute!(record)
      record.save!

      recalculate_payroll(request, period, actor)

      contract::Approval.new(status: :applied, snapshot: snapshot,
                             worked_minutes: record.worked_minutes, duration_severity: record.duration_severity)
    end

    # Refusals, in order: no attendance record; the request month's payroll
    # period finalized / paid. A RecordInvalid while restoring propagates (the
    # caller maps it); any other error propagates and rolls the cancellation back.
    def correction_cancelled(request:, field:, snapshot:, actor:)
      record = record_for(request)
      return :no_attendance_record unless record

      period = locked_period_for(request)
      return :payroll_locked if period&.locked?

      if field == :check_in
        record.check_in_at     = snapshot.check_in_at
        record.check_in_source = snapshot.check_in_source
      else
        record.check_out_at     = snapshot.check_out_at
        record.check_out_source = snapshot.check_out_source
      end
      record.save!
      Attendance::RecordRecomputer.recompute!(record)
      record.save!

      recalculate_payroll(request, period, actor)

      :reverted
    end

    # Decisions A / B / C (Pilot 10 M4-3): the employee's entry in the (locked,
    # open) period is re-derived from attendance by Payroll::EntryRecalculator, as
    # every other attendance mutation does — penalty lines created / updated /
    # removed (A), approved permission minutes applied (B), worked days, overtime
    # and absences re-derived, management decisions (overtime override, waivers,
    # addition cancellations) re-applied (C). Inside the caller's transaction;
    # any error propagates and rolls the approval / cancellation back.
    #
    # Only an EXISTING entry is recalculated (EntryCalculator would create one):
    # a punch correction never creates a payroll entry. The entry row is locked
    # after the period row (lock order request → period → entry, as
    # Payroll::OvertimeRecalculator).
    def recalculate_payroll(request, period, actor)
      return unless period

      entry = PayrollEntry.lock.find_by(payroll_period: period, user: request.user)
      return unless entry

      result = Payroll::EntryRecalculator.call(user: request.user, period: period, triggered_by: actor)
      # A real error (not ActiveRecord::Rollback, which a joined transaction
      # block would swallow): the caller's whole transaction must roll back.
      raise RecalculationFailed, result.error.to_s unless result.ok?
    end

    class RecalculationFailed < StandardError; end

    def record_for(request)
      AttendanceRecord
        .includes(shift_assignment: [ :rule_profile, { shift: :penalty_rules } ])
        .find_by(user: request.user, work_date: request.requested_for_date)
    end

    # The payroll period of the request's month (any status), row-locked until
    # the caller's transaction ends; nil when there is none.
    def locked_period_for(request)
      PayrollPeriod.lock.find_by(
        business:     request.user.business,
        period_month: request.requested_for_date.month,
        period_year:  request.requested_for_date.year
      )
    end

    # Worked minutes the record would have with the correction, recomputed on an
    # unsaved copy so nothing is persisted; nil without a record, a moment or the
    # other punch.
    def projected_worked_minutes(record, field, effective_at, check_in_at, check_out_at)
      return unless record && effective_at

      copy = record.dup
      copy.check_in_at  = field == :check_in  ? effective_at : check_in_at
      copy.check_out_at = field == :check_out ? effective_at : check_out_at
      Attendance::RecordRecomputer.recompute!(copy)
      copy.worked_minutes
    end
  end
end
