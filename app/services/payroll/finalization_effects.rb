module Payroll
  # Attendance & Payroll contract for the effects another domain must apply
  # when a payroll period is finalized or reopened (Milestone 2 — Finance &
  # Sales Expenses, M2; module-boundaries.md §12.1 / §14.1 A).
  #
  # Payroll defines WHAT it needs; the owning domain implements it and
  # registers the implementation at boot (config/initializers/
  # payroll_finalization_effects.rb). Payroll code never names that
  # implementation, so this module has no dependency on Finance & Sales.
  #
  # Calls are synchronous, in-process and run inside the caller's database
  # transaction: an error raised by the handler propagates, so the
  # finalization / reopen rolls back exactly as before. No event bus, HTTP or
  # asynchronous work.
  #
  # A handler must respond to:
  #   period_finalized(period:, actor:, employer_insurance_total:, employer_insurance_by_branch:)
  #     — after the period becomes "finalized"; the employer insurance cost is
  #       passed as data ({branch_id => amount}, Payroll::EmployerInsuranceCost)
  #       so the handler never reads payroll entries itself (§14.1 A)
  #   period_reopened(period:, actor:, reason:)
  #     — after it leaves "finalized" for review
  module FinalizationEffects
    OPERATIONS = %i[period_finalized period_reopened].freeze

    # Raised when an effect is requested before any handler is registered —
    # payroll money effects are never silently skipped.
    class NotRegistered < StandardError; end

    class << self
      def register(handler)
        missing = OPERATIONS.reject { |operation| handler.respond_to?(operation) }
        raise ArgumentError, "#{handler} does not implement #{missing.join(', ')}" if missing.any?

        @handler = handler
      end

      def handler
        @handler || raise(NotRegistered, "No Payroll::FinalizationEffects handler is registered")
      end

      def period_finalized(period:, actor:, employer_insurance_total:, employer_insurance_by_branch:)
        handler.period_finalized(period: period, actor: actor,
                                 employer_insurance_total: employer_insurance_total,
                                 employer_insurance_by_branch: employer_insurance_by_branch)
      end

      def period_reopened(period:, actor:, reason:)
        handler.period_reopened(period: period, actor: actor, reason: reason)
      end
    end
  end
end
