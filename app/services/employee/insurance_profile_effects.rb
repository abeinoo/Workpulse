module Employee
  # Workforce contract for the payroll side of an employee insurance profile
  # (Pilot 8 — Employee Insurance Profile, M2; module-boundaries.md §12.1 /
  # §14.2 #5).
  #
  # The insurance profile is Workforce data; payroll periods, entries and their
  # recalculation are owned by Attendance & Payroll, which sits downstream of
  # Workforce, so Workforce must not name them. Workforce defines WHAT the
  # insurance screens need; Attendance & Payroll implements it and registers the
  # implementation at boot (config/initializers/employee_insurance_profile_effects.rb).
  # This module has no dependency on Attendance & Payroll. Attendance & Payroll
  # still reads the profile itself when it generates entries (the allowed
  # direction) — that read is not part of this contract.
  #
  # Calls are synchronous and in-process; no event bus, job or HTTP. A handler
  # error propagates to the caller. The caller decides how to isolate it: the
  # insurance profile change is already committed when profile_changed is
  # called, and a failing payroll effect must not fail that change.
  #
  # A handler must respond to:
  #   profile_changed(user:, actor:)
  #     — the employee's insurance profile was saved (created or updated); the
  #       handler brings the payroll it owns in line with it. user is the
  #       employee (User), actor the User who made the change. Its return value
  #       is not used.
  #   payroll_notice_for(user:)
  #     — which payroll an insurance change of this employee would affect, as
  #       one of NOTICES (a Symbol — never a payroll record):
  #         :none      the employee has never appeared in a payroll period
  #         :active    exactly one period that is still open (not finalized or
  #                    paid) includes them
  #         :mixed     more than one open period includes them
  #         :finalized every period that includes them is finalized or paid
  module InsuranceProfileEffects
    OPERATIONS = %i[profile_changed payroll_notice_for].freeze
    NOTICES    = %i[none active mixed finalized].freeze

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
        @handler || raise(NotRegistered, "No Employee::InsuranceProfileEffects handler is registered")
      end

      def profile_changed(user:, actor:)
        handler.profile_changed(user: user, actor: actor)
        nil
      end

      def payroll_notice_for(user:)
        notice = handler.payroll_notice_for(user: user)
        return notice if NOTICES.include?(notice)

        raise ArgumentError, "#{handler}.payroll_notice_for returned #{notice.inspect}, expected one of #{NOTICES.inspect}"
      end
    end
  end
end
