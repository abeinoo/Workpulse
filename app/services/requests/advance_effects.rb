module Requests
  # Workforce contract for the financial effect of paying a salary-advance
  # request (Batch A — Advance boundary; module-boundaries.md §12.1 / §14.2 #2).
  #
  # The request and its lifecycle (approve, pay, cancel) are Workforce's; the
  # Advance ledger it creates — later deducted and settled by payroll — is owned
  # by Attendance & Payroll, which sits downstream of Workforce, so Workforce
  # must not write it. Workforce defines WHAT it needs when an advance is paid;
  # Attendance & Payroll implements it and registers the implementation at boot
  # (config/initializers/request_advance_effects.rb). This module has no
  # dependency on Attendance & Payroll.
  #
  # Calls are synchronous and in-process — no event bus, job or HTTP — and run in
  # the caller's transaction: Requests::Approver#pay calls it after locking the
  # request row and marking it paid, so the request and its Advance are written
  # together or not at all. An unexpected handler error propagates to the caller.
  #
  # A handler must respond to:
  #   advance_paid(request:, paid_at:)
  #     — the salary-advance request (an EmployeeRequest) is being paid at
  #       paid_at. The handler records the advance for request.user for the full
  #       request.amount, issued at paid_at, and returns nil. A record that
  #       cannot be saved raises ActiveRecord::RecordInvalid.
  module AdvanceEffects
    OPERATIONS = %i[advance_paid].freeze

    # Raised when an operation is requested before any handler is registered —
    # a payment is never recorded without its advance.
    class NotRegistered < StandardError; end

    class << self
      def register(handler)
        missing = OPERATIONS.reject { |operation| handler.respond_to?(operation) }
        raise ArgumentError, "#{handler} does not implement #{missing.join(', ')}" if missing.any?

        @handler = handler
      end

      def handler
        @handler || raise(NotRegistered, "No Requests::AdvanceEffects handler is registered")
      end

      def advance_paid(request:, paid_at:)
        handler.advance_paid(request: request, paid_at: paid_at)
        nil
      end
    end
  end
end
