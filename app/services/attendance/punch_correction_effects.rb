module Attendance
  # Attendance & Payroll implementation of the Workforce
  # Requests::PunchCorrectionEffects contract (registered in
  # config/initializers/request_punch_correction_effects.rb):
  #
  #   correction_facts     → the attendance window (Attendance::PunchWindow), the
  #                          record's projected recomputation (RecordRecomputer on
  #                          an unsaved copy) and Attendance::DurationCheck — the
  #                          same reads Requests::PunchCorrectionAssessment makes
  #   correction_approved  → not yet implemented (M3 + M4)
  #   correction_cancelled → not yet implemented (M3 + M4)
  #
  # Approval and cancellation are still performed by Workforce
  # (Requests::PunchCorrectionApplier, Requests::Canceller#rollback_punch_correction).
  # Delegating to them from here would route Workforce through a contract that
  # calls straight back into Workforce (the circular shape rejected in Pilot 9
  # M3-B), so the two operations raise until their logic moves here in M4,
  # together with the M3 routing of their callers. No caller uses this
  # implementation in M2.
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
        shift_starts_at:          window.shift_starts_at,
        shift_ends_at:            window.shift_ends_at,
        projected_worked_minutes: projected,
        duration_severity:        Attendance::DurationCheck.severity(projected, business: request.user.business)
      )
    end

    def correction_approved(request:, field:, effective_at:)
      raise NotImplementedError, "#{name}.correction_approved lands with Pilot 10 M3 + M4"
    end

    def correction_cancelled(request:, field:, snapshot:)
      raise NotImplementedError, "#{name}.correction_cancelled lands with Pilot 10 M3 + M4"
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
