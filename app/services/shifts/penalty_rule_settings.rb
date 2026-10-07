module Shifts
  # Workforce contract for the penalty rules edited on the Shift form (Pilot 4 —
  # Penalty Rules, M2; module-boundaries.md §12.1 / §14.2 #9).
  #
  # Penalty rules are owned by Attendance & Payroll, which sits downstream of
  # Workforce, so Workforce must not name them. Workforce defines WHAT the shift
  # form needs; Attendance & Payroll implements it and registers the
  # implementation at boot (config/initializers/shift_penalty_rule_settings.rb).
  # This module has no dependency on Attendance & Payroll.
  #
  # The handler only stages the changes on the shift: they are validated and
  # persisted by the shift's own save, in the same transaction, so a failing
  # rule leaves the shift and every rule unchanged. Authorization stays with the
  # caller (ShiftPolicy#update? / #create?, manage_shifts).
  #
  # A handler must respond to:
  #   assign(shift:, rows:)
  #     — rows are the form's rule rows (an Array, or a Hash keyed by row
  #       index) with the keys id, rule_type, threshold_minutes,
  #       deduction_type, deduction_value and _destroy. A row with an id updates
  #       (or, with _destroy, removes) that rule of this shift; a row without an
  #       id adds one; an all-blank new row is ignored; an id that is not one of
  #       this shift's rules raises ActiveRecord::RecordNotFound.
  module PenaltyRuleSettings
    OPERATIONS = %i[assign].freeze

    # Raised when rule changes are requested before any handler is registered —
    # submitted rules are never silently dropped.
    class NotRegistered < StandardError; end

    class << self
      def register(handler)
        missing = OPERATIONS.reject { |operation| handler.respond_to?(operation) }
        raise ArgumentError, "#{handler} does not implement #{missing.join(', ')}" if missing.any?

        @handler = handler
      end

      def handler
        @handler || raise(NotRegistered, "No Shifts::PenaltyRuleSettings handler is registered")
      end

      def assign(shift:, rows:)
        handler.assign(shift: shift, rows: rows)
      end
    end
  end
end
