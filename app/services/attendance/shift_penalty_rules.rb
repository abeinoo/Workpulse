module Attendance
  # Attendance & Payroll implementation of the Workforce Shifts::PenaltyRuleSettings
  # contract (registered in config/initializers/shift_penalty_rule_settings.rb).
  #
  # M2: delegates to the existing nested-attributes behaviour of Shift
  # (accepts_nested_attributes_for :penalty_rules, reject_if: :all_blank,
  # allow_destroy: true), so staging, the 404 for a rule outside the shift,
  # validation and the shared transaction are exactly as before. The logic moves
  # here in M4.
  module ShiftPenaltyRules
    module_function

    def assign(shift:, rows:)
      shift.penalty_rules_attributes = rows
    end
  end
end
