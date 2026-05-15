module Attendance
  # Evaluates penalty rules against a completed attendance record.
  # Called by the payroll generator — NOT at check-in/out time.
  #
  # daily_salary: the employee's effective daily rate at the time of payroll generation.
  class PenaltyCalculator
    PenaltyResult = Struct.new(:late_penalty, :early_leave_penalty, :total_deduction, keyword_init: true)

    def self.calculate(record:, daily_salary:, late_minutes_override: nil, early_leave_minutes_override: nil)
      new(
        record:                       record,
        daily_salary:                 daily_salary,
        late_minutes_override:        late_minutes_override,
        early_leave_minutes_override: early_leave_minutes_override
      ).calculate
    end

    def initialize(record:, daily_salary:, late_minutes_override: nil, early_leave_minutes_override: nil)
      @record                       = record
      @daily_salary                 = daily_salary.to_f
      @late_minutes_override        = late_minutes_override
      @early_leave_minutes_override = early_leave_minutes_override
    end

    def calculate
      shift = @record.shift_assignment&.shift
      return zero_result unless shift

      if shift.hour_based?
        # For flexible shifts the only penalty concept is hour shortfall, stored as early_leave_minutes.
        # Apply all penalty rules on the shift (any rule_type) so the admin's configuration is honoured
        # regardless of whether they chose late_arrival or early_leave as the rule type.
        shortfall_penalty = apply_rules(effective_early_leave_minutes, shift.penalty_rules)
        PenaltyResult.new(
          late_penalty:        0.0,
          early_leave_penalty: shortfall_penalty,
          total_deduction:     shortfall_penalty
        )
      else
        late_penalty        = apply_rules(effective_late_minutes, shift.penalty_rules.for_late_arrival)
        early_leave_penalty = apply_rules(effective_early_leave_minutes, shift.penalty_rules.for_early_leave)
        PenaltyResult.new(
          late_penalty:        late_penalty,
          early_leave_penalty: early_leave_penalty,
          total_deduction:     late_penalty + early_leave_penalty
        )
      end
    end

    private

    def effective_late_minutes
      @late_minutes_override.nil? ? @record.late_minutes.to_i : @late_minutes_override.to_i
    end

    def effective_early_leave_minutes
      @early_leave_minutes_override.nil? ? @record.early_leave_minutes.to_i : @early_leave_minutes_override.to_i
    end

    def apply_rules(minutes, rules_scope)
      return 0.0 if minutes.to_i <= 0

      rule = PenaltyRule.applicable_for(minutes, rules_scope.ordered_by_threshold)
      return 0.0 unless rule

      if rule.fixed_amount?
        rule.deduction_value.to_f
      else
        (@daily_salary * rule.deduction_value / 100.0).round(2)
      end
    end

    def zero_result
      PenaltyResult.new(late_penalty: 0.0, early_leave_penalty: 0.0, total_deduction: 0.0)
    end
  end
end
