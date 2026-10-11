module Requests
  # Workforce contract for the attendance and payroll side of a punch-correction
  # request (Pilot 10 — Punch Correction, M2; module-boundaries.md §12.1 / §14.2
  # #3 and the punch half of #4).
  #
  # The request, its lifecycle (approve, reject, cancel), the reviewer's chosen
  # moment, the snapshot persisted on the request and the request audit are
  # Workforce's. The attendance record, its recomputation, the attendance
  # window, duration checks, penalty lines, payroll periods and entries belong
  # to Attendance & Payroll, which sits downstream of Workforce, so Workforce
  # must not name them. Workforce defines WHAT it needs; Attendance & Payroll
  # implements it and registers the implementation at boot
  # (config/initializers/request_punch_correction_effects.rb). This module has
  # no dependency on Attendance & Payroll.
  #
  # Calls are synchronous and in-process — no event bus, job or HTTP.
  # correction_approved / correction_cancelled run inside the caller's
  # transaction (the approve / cancel transaction); correction_facts reads only.
  # An unexpected handler error propagates; the caller decides how to report it.
  #
  # Arguments the caller computes (request data, so they stay in Workforce):
  #   field        — :check_in or :check_out (EmployeeRequest#correction_field)
  #   effective_at — the corrected punch moment (the reviewer's final date / time
  #                  in the business timezone)
  #   baseline / snapshot — the punches before the correction (Snapshot), as
  #                  persisted on the request when it was applied
  #
  # A handler must respond to:
  #   correction_facts(request:, field:, effective_at:, baseline:)
  #     — read-only facts about the correction against the employee's attendance
  #       for the request's date: a Facts. baseline nil → judged against the
  #       live attendance record; a Snapshot → against the punches before an
  #       already-applied correction. Never writes anything.
  #   correction_approved(request:, field:, effective_at:)
  #     — the request is being approved: apply the correction to attendance and
  #       bring the payroll it owns in line. An Approval: status :applied with the
  #       Snapshot of the punches it replaced and the resulting worked minutes /
  #       duration severity, or one of the REFUSALS (nothing written). It never
  #       writes the request, its status, approved_punch_at, its snapshot or the
  #       audit — Workforce persists those from the result.
  #   correction_cancelled(request:, field:, snapshot:)
  #     — the approved correction is being cancelled: restore the attendance
  #       record from the snapshot and the payroll it owns. One of
  #       CANCEL_RESULTS (a Symbol): :reverted, or a refusal (nothing written).
  module PunchCorrectionEffects
    OPERATIONS = %i[correction_facts correction_approved correction_cancelled].freeze

    FIELDS = %i[check_in check_out].freeze

    # Approval refusals: the payroll period of the request's month is finalized /
    # paid; there is no attendance record for the date; the corrected punches
    # would be out of order (a check-out correction not strictly after the
    # check-in, or a check-out before the check-in).
    REFUSALS = %i[payroll_locked no_attendance_record check_out_not_after_check_in check_out_before_check_in].freeze

    CANCEL_RESULTS = %i[reverted payroll_locked no_attendance_record].freeze

    # The punches before a correction (persisted by Workforce on the request).
    Snapshot = Struct.new(:check_in_at, :check_out_at, :check_in_source, :check_out_source, keyword_init: true)

    # Read-only attendance facts for a correction.
    #   record_found             — an attendance record exists for the date
    #   check_in_at / _out_at    — its punches (or the baseline's)
    #   inside_window            — effective_at falls inside the expected attendance window
    #   shift_name               — the shift assigned on that date (nil without one)
    #   shift_required_hours     — its required hours (hour-based shifts; nil otherwise / without one)
    #   shift_starts_at / _ends_at — the scheduled shift on that date (nil without a fixed-time shift)
    #   projected_worked_minutes — worked minutes the record would have with the correction (nil if a punch is missing)
    #   duration_severity        — nil, :suspicious or :critical for the projected minutes
    Facts = Struct.new(:record_found, :check_in_at, :check_out_at, :inside_window, :shift_name, :shift_required_hours,
                       :shift_starts_at, :shift_ends_at, :projected_worked_minutes, :duration_severity,
                       keyword_init: true) do
      def record_found? = record_found
      def inside_window? = inside_window
    end

    # The outcome of correction_approved.
    Approval = Struct.new(:status, :snapshot, :worked_minutes, :duration_severity, keyword_init: true) do
      def applied? = status == :applied
      def refused? = !applied?
    end

    # Raised when an operation is requested before any handler is registered —
    # an attendance / payroll effect is never silently skipped.
    class NotRegistered < StandardError; end

    class << self
      def register(handler)
        missing = OPERATIONS.reject { |operation| handler.respond_to?(operation) }
        raise ArgumentError, "#{handler} does not implement #{missing.join(', ')}" if missing.any?

        @handler = handler
      end

      def handler
        @handler || raise(NotRegistered, "No Requests::PunchCorrectionEffects handler is registered")
      end

      def correction_facts(request:, field:, effective_at:, baseline: nil)
        check_field!(field)
        check_snapshot!(baseline, allow_nil: true)

        facts = handler.correction_facts(request: request, field: field, effective_at: effective_at, baseline: baseline)
        return facts if facts.is_a?(Facts)

        raise ArgumentError, "#{handler}.correction_facts returned #{facts.class}, expected #{Facts}"
      end

      def correction_approved(request:, field:, effective_at:)
        check_field!(field)

        approval = handler.correction_approved(request: request, field: field, effective_at: effective_at)
        check_approval!(approval)
        approval
      end

      def correction_cancelled(request:, field:, snapshot:)
        check_field!(field)
        check_snapshot!(snapshot)

        result = handler.correction_cancelled(request: request, field: field, snapshot: snapshot)
        return result if CANCEL_RESULTS.include?(result)

        raise ArgumentError, "#{handler}.correction_cancelled returned #{result.inspect}, expected one of #{CANCEL_RESULTS.inspect}"
      end

      private

      def check_field!(field)
        raise ArgumentError, "field must be one of #{FIELDS.inspect}, got #{field.inspect}" unless FIELDS.include?(field)
      end

      def check_snapshot!(snapshot, allow_nil: false)
        return if snapshot.nil? && allow_nil
        raise ArgumentError, "expected a #{Snapshot}, got #{snapshot.class}" unless snapshot.is_a?(Snapshot)
      end

      def check_approval!(approval)
        raise ArgumentError, "expected a #{Approval}, got #{approval.class}" unless approval.is_a?(Approval)

        if approval.applied?
          raise ArgumentError, "an applied Approval needs a #{Snapshot}" unless approval.snapshot.is_a?(Snapshot)
        elsif !REFUSALS.include?(approval.status)
          raise ArgumentError, "unknown Approval status #{approval.status.inspect}, expected :applied or one of #{REFUSALS.inspect}"
        end
      end
    end
  end
end
