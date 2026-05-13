module Attendance
  # Evaluates penalty rules against a completed attendance record.
  # Called by the payroll generator — NOT at check-in/out time.
  #
  # daily_salary: the employee's effective daily rate at the time of payroll generation.
  class PenaltyCalculator
    PenaltyResult = Struct.new(:late_penalty, :early_leave_penalty, :total_deduction, keyword_init: true)

    def self.calculate(record:, daily_salary:)
      new(record: record, daily_salary: daily_salary).calculate
    end

    def initialize(record:, daily_salary:)
      @record       = record
      @daily_salary = daily_salary.to_f
    end

    def calculate
      shift = @record.shift_assignment&.shift
      return zero_result unless shift

      late_penalty        = apply_rules(@record.late_minutes, shift.penalty_rules.for_late_arrival)
      early_leave_penalty = apply_rules(@record.early_leave_minutes, shift.penalty_rules.for_early_leave)

      PenaltyResult.new(
        late_penalty:        late_penalty,
        early_leave_penalty: early_leave_penalty,
        total_deduction:     late_penalty + early_leave_penalty
      )
    end

    private

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
