module Requests
  # Workforce contract for the payroll effect of a late-permission or
  # early-leave request (Pilot 9 — Request Permission Payroll Effects, M2;
  # module-boundaries.md §12.1 / §14.2 #4).
  #
  # The request and its lifecycle (approve, cancel) are Workforce's; the payroll
  # periods, entries and penalty lines the permission affects are owned by
  # Attendance & Payroll, which sits downstream of Workforce, so Workforce must
  # not name them. Workforce defines WHAT it needs when a permission is approved
  # or cancelled; Attendance & Payroll implements it and registers the
  # implementation at boot (config/initializers/request_permission_payroll_effects.rb).
  # This module has no dependency on Attendance & Payroll.
  #
  # Calls are synchronous and in-process — no event bus, job or HTTP — and run in
  # the caller's transaction where there is one (the cancel transaction). An
  # unexpected handler error propagates to the caller.
  #
  # A handler must respond to:
  #   permission_approved(request:)
  #     — the request (an EmployeeRequest) was just approved. The handler brings
  #       the payroll it owns in line with the approved permission minutes, or
  #       does nothing when there is nothing to change (not a permission, no
  #       open period, entry, attendance record or penalty line). There is no
  #       refusal: approval is never blocked by payroll. Its return value is not
  #       used (nil).
  #   permission_cancelled(request:)
  #     — the approved request is being cancelled, inside the cancel
  #       transaction. The handler reverts the permission's payroll effect and
  #       answers one of CANCEL_RESULTS (a Symbol — never a payroll record):
  #         :reverted  the effect was reverted, or there was nothing to revert
  #         :refused   the payroll it affected is locked (finalized or paid); the
  #                    caller must keep the request approved
  #       Any other failure raises.
  module PermissionPayrollEffects
    OPERATIONS     = %i[permission_approved permission_cancelled].freeze
    CANCEL_RESULTS = %i[reverted refused].freeze

    # Raised when an operation is requested before any handler is registered —
    # a payroll effect is never silently skipped.
    class NotRegistered < StandardError; end

    class << self
      def register(handler)
        missing = OPERATIONS.reject { |operation| handler.respond_to?(operation) }
        raise ArgumentError, "#{handler} does not implement #{missing.join(', ')}" if missing.any?

        @handler = handler
      end

      def handler
        @handler || raise(NotRegistered, "No Requests::PermissionPayrollEffects handler is registered")
      end

      def permission_approved(request:)
        handler.permission_approved(request: request)
        nil
      end

      def permission_cancelled(request:)
        result = handler.permission_cancelled(request: request)
        return result if CANCEL_RESULTS.include?(result)

        raise ArgumentError, "#{handler}.permission_cancelled returned #{result.inspect}, expected one of #{CANCEL_RESULTS.inspect}"
      end
    end
  end
end
