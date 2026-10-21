module Requests
  # Workforce contract for what employee-request screens and validation read
  # from Attendance & Payroll (Batch V — request-validation reads, D-A5;
  # module-boundaries.md §12.2 WF → AP).
  #
  # The request, its form, its show page, its validation and its authorization
  # are Workforce's. The advance limit (derived from the employee's salary and
  # outstanding advances), salary visibility and its audit, the attendance of a
  # date, recent check-ins and the attendance-duration thresholds belong to
  # Attendance & Payroll, which sits downstream of Workforce, so Workforce must
  # not name them. Workforce defines WHAT it needs; Attendance & Payroll
  # implements it and registers the implementation at boot. This module has no
  # dependency on Attendance & Payroll.
  #
  # Calls are synchronous, in-process and read-only, except that
  # advance_limit_for records the salary view it discloses (an audit row, as
  # every salary view does). An unexpected handler error propagates.
  #
  # A handler must respond to:
  #   advance_limit(user:)
  #     — the salary-advance limit of `user` as of today: an AdvanceLimit, or
  #       nil when the business configures no limit (advances unrestricted). A
  #       user without a salary in force gets an AdvanceLimit with no_profile
  #       true and available 0 — never nil. Writes nothing.
  #   advance_limit_for(user:, viewer:)
  #     — the limit of `user` as shown to `viewer` on the request form: an
  #       AdvanceLimitView. In this order:
  #         * no limit configured      → limit nil, hidden false, nothing recorded;
  #         * viewer is the user       → limit, hidden false, nothing recorded;
  #         * viewer may not see the
  #           user's salary            → limit nil, hidden true, nothing recorded;
  #         * otherwise                → limit, hidden false, and — unless the
  #           limit is no_profile — one salary view recorded for actor `viewer`,
  #           employee `user`, source "request_advance_limit".
  #       "May see the salary" is the rule of salary_visible?.
  #   salary_visible?(viewer:, employee:)
  #     — may `viewer` see the salary of ANOTHER employee? true or false; the
  #       rule covers other employees only and is false for viewer == employee
  #       (callers decide one's own requests before asking). Writes nothing.
  #   attendance_day(user:, date:)
  #     — the attendance of `user` for work date `date`: an AttendanceDay, or nil
  #       when there is none. Writes nothing.
  #   recent_check_ins(user:)
  #     — the check-ins of `user` whose work date is within RECENT_CHECK_INS_DAYS
  #       days before Date.current (inclusive): a Hash of work date
  #       ("YYYY-MM-DD") => check-in in the business's timezone
  #       ("YYYY-MM-DDTHH:MM"), in the order the store returns them. Writes
  #       nothing.
  #   duration_threshold_hours(severity:, business:)
  #     — the configured hour threshold a duration severity was measured
  #       against: the critical threshold for :critical, the suspicious one for
  #       any other value. An Integer. Writes nothing.
  module RequestFormReads
    OPERATIONS = %i[
      advance_limit advance_limit_for salary_visible? attendance_day recent_check_ins duration_threshold_hours
    ].freeze

    RECENT_CHECK_INS_DAYS = 62

    # The advance limit. Amounts are passed through exactly as Attendance &
    # Payroll computes them (validation messages and the form hint format them).
    #   description_key — i18n suffix of the form hint ("monthly_basis" | "daily_basis"; "no_profile" when no_profile)
    #   max_amount      — the ceiling before outstanding advances
    #   outstanding     — this month's committed advances
    #   available       — what may still be requested
    #   no_profile      — the employee has no salary in force
    AdvanceLimit = Struct.new(:description_key, :max_amount, :outstanding, :available, :no_profile,
                              keyword_init: true) do
      def no_profile? = !!no_profile
    end

    # The limit as the request form may show it: limit nil with hidden true when
    # the viewer may not see it; limit nil with hidden false when there is none.
    AdvanceLimitView = Struct.new(:limit, :hidden, keyword_init: true) do
      def hidden? = !!hidden
    end

    # One employee's attendance for a work date, as the request show page reads it.
    #   check_in_at / check_out_at — the punches (Time; check_out_at nil while missing)
    #   status                     — the attendance status (String)
    #   worked_minutes             — worked minutes (nil until checked out)
    #   duration_severity          — nil, :suspicious or :critical for worked_minutes
    AttendanceDay = Struct.new(:check_in_at, :check_out_at, :status, :worked_minutes, :duration_severity,
                               keyword_init: true)

    # Raised when a read is requested before any handler is registered.
    class NotRegistered < StandardError; end

    class << self
      def register(handler)
        missing = OPERATIONS.reject { |operation| handler.respond_to?(operation) }
        raise ArgumentError, "#{handler} does not implement #{missing.join(', ')}" if missing.any?

        @handler = handler
      end

      def handler
        @handler || raise(NotRegistered, "No Requests::RequestFormReads handler is registered")
      end

      def advance_limit(user:)
        check_result(:advance_limit, handler.advance_limit(user: user), AdvanceLimit, allow_nil: true)
      end

      def advance_limit_for(user:, viewer:)
        view = check_result(:advance_limit_for, handler.advance_limit_for(user: user, viewer: viewer), AdvanceLimitView)
        check_result(:advance_limit_for, view.limit, AdvanceLimit, allow_nil: true)
        view
      end

      def salary_visible?(viewer:, employee:)
        check_result(:salary_visible?, handler.salary_visible?(viewer: viewer, employee: employee), TrueClass, FalseClass)
      end

      def attendance_day(user:, date:)
        check_result(:attendance_day, handler.attendance_day(user: user, date: date), AttendanceDay, allow_nil: true)
      end

      def recent_check_ins(user:)
        check_result(:recent_check_ins, handler.recent_check_ins(user: user), Hash)
      end

      def duration_threshold_hours(severity:, business:)
        check_result(:duration_threshold_hours, handler.duration_threshold_hours(severity: severity, business: business), Integer)
      end

      private

      def check_result(operation, result, *types, allow_nil: false)
        return result if result.nil? && allow_nil
        return result if types.any? { |type| result.is_a?(type) }

        expected = types.map(&:to_s).join(" or ")
        expected += " or nil" if allow_nil
        raise ArgumentError, "#{handler}.#{operation} returned #{result.class}, expected #{expected}"
      end
    end
  end
end
