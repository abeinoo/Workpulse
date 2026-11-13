module Employee
  # Workforce contract: "does a protected payroll period overlap these dates?"
  # (R3.2; roadmap revision 19, §2 W OD-1, OD-10, OD-12, OD-13; §19.14).
  #
  # The attendance requirement history and the Employment Start Date are
  # Workforce data; payroll periods and their status are owned by Attendance &
  # Payroll, downstream of Workforce, so Workforce must not name them. Workforce
  # defines WHAT it needs to know; Attendance & Payroll implements it and
  # registers the implementation at boot
  # (config/initializers/employee_payroll_date_protection.rb). Calls are
  # synchronous and in-process; a handler error propagates to the caller.
  #
  # A protected period is one that is under review or later; its stage is a
  # Workforce word (one of STAGES), never a payroll status:
  #   :in_review   the period is being reviewed
  #   :finalized   the period is finalized or paid
  #
  # A handler must respond to:
  #   lock_protected_range(business_id:, from:, through:)
  #     — D4 refusal check for a backdated requirement change. Runs inside the
  #       caller's open transaction (after the caller's employee lock), takes
  #       the locks of §19.14 so no concurrent submission for review can slip
  #       past it, and returns the EARLIEST protected period of the business
  #       overlapping [from, through] as a Protected, or nil. Every period of the
  #       business counts, whether or not the employee has an entry in it.
  #   protected_ranges(business_id:, from:, through:)
  #     — every protected period of the business overlapping [from, through],
  #       earliest first, as an Array of Protected; read-only, no locks (the
  #       start-date correction's warning, OD-13).
  #
  # Fails closed: no registered handler raises NotRegistered, and an answer
  # outside the contract raises ContractViolation — a check is never skipped.
  module PayrollDateProtection
    OPERATIONS = %i[lock_protected_range protected_ranges].freeze
    STAGES     = %i[in_review finalized].freeze

    Protected = Data.define(:starts_on, :ends_on, :stage)

    class NotRegistered < StandardError; end
    class ContractViolation < StandardError; end

    class << self
      def register(handler)
        missing = OPERATIONS.reject { |operation| handler.respond_to?(operation) }
        raise ArgumentError, "#{handler} does not implement #{missing.join(', ')}" if missing.any?

        @handler = handler
      end

      def handler
        @handler || raise(NotRegistered, "No Employee::PayrollDateProtection handler is registered")
      end

      def lock_protected_range(business_id:, from:, through:)
        answer = handler.lock_protected_range(business_id: business_id, from: from, through: through)
        answer.nil? ? nil : checked(answer, :lock_protected_range)
      end

      def protected_ranges(business_id:, from:, through:)
        answers = handler.protected_ranges(business_id: business_id, from: from, through: through)
        raise ContractViolation, "#{handler}.protected_ranges returned #{answers.inspect}, expected an Array" unless answers.is_a?(Array)

        answers.map { |answer| checked(answer, :protected_ranges) }
      end

      private

      def checked(answer, operation)
        valid = answer.is_a?(Protected) && STAGES.include?(answer.stage) &&
                answer.starts_on.is_a?(Date) && answer.ends_on.is_a?(Date)
        return answer if valid

        raise ContractViolation, "#{handler}.#{operation} returned #{answer.inspect}, expected a Protected with a stage in #{STAGES.inspect}"
      end
    end
  end
end
