module Salary
  # Computes overtime minutes and the corresponding pay for one attendance record.
  #
  # grace_minutes is an ELIGIBILITY GATE, not a deduction: raw overtime (minutes
  # worked beyond scheduled_duration) must reach grace_minutes before any overtime
  # counts. Once it does, ALL raw overtime minutes count — the threshold itself
  # is included, never subtracted.
  #
  # A blank shift.overtime_rate_multiplier disables overtime entirely (zero).
  #
  # Rule profile overrides (highest priority):
  #   overtime_enabled:    false → always returns zero
  #   overtime_multiplier: overrides shift.overtime_rate_multiplier
  #   break_minutes:       deducted from worked before computing overtime
  #
  # Priority: rule_profile > passed multiplier > shift default
  class OvertimeCalculator
    OvertimeResult = Struct.new(:overtime_minutes, :overtime_pay, keyword_init: true)

    def self.calculate(record:, daily_rate:, multiplier: nil, grace_minutes: 0, rule_profile: nil)
      new(record: record, daily_rate: daily_rate, multiplier: multiplier,
          grace_minutes: grace_minutes, rule_profile: rule_profile).calculate
    end

    def initialize(record:, daily_rate:, multiplier: nil, grace_minutes: 0, rule_profile: nil)
      @record        = record
      @daily_rate    = daily_rate.to_f
      @multiplier    = multiplier&.to_f
      @grace_minutes = grace_minutes.to_i
      @rule_profile  = rule_profile
    end

    def calculate
      return zero_result if @rule_profile && !@rule_profile.overtime_enabled?

      shift = @record.shift_assignment&.shift
      return zero_result unless shift
      return zero_result unless shift.overtime_enabled?

      worked = @record.worked_minutes.to_i
      return zero_result if worked <= 0

      overtime_mins = overtime_minutes(shift, worked)
      return zero_result if overtime_mins <= 0

      OvertimeResult.new(
        overtime_minutes: overtime_mins,
        overtime_pay:     overtime_pay(shift, overtime_mins)
      )
    end

    private

    def overtime_minutes(shift, worked)
      scheduled = shift.duration_minutes.to_i
      return 0 if scheduled.zero?

      effective_worked = worked - @rule_profile&.effective_break_minutes.to_i
      raw_overtime      = effective_worked - scheduled
      return 0 if raw_overtime <= 0
      return 0 if raw_overtime < @grace_minutes

      raw_overtime
    end

    def overtime_pay(shift, overtime_mins)
      shift_hours = shift.duration_minutes.to_f / 60
      return 0.0 if shift_hours.zero?

      hourly_rate    = @daily_rate / shift_hours
      overtime_hours = overtime_mins / 60.0
      multiplier     = @rule_profile&.overtime_multiplier&.to_f ||
                       @multiplier ||
                       shift.overtime_rate_multiplier.to_f

      (hourly_rate * overtime_hours * multiplier).round(2)
    end

    def zero_result
      OvertimeResult.new(overtime_minutes: 0, overtime_pay: 0.0)
    end
  end
end
