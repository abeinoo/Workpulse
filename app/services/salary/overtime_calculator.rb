module Salary
  # Computes overtime minutes and the corresponding pay for one attendance record.
  # Overtime = minutes worked beyond the scheduled shift duration.
  # Pay = overtime_hours * hourly_rate * shift.overtime_rate_multiplier
  class OvertimeCalculator
    OvertimeResult = Struct.new(:overtime_minutes, :overtime_pay, keyword_init: true)

    def self.calculate(record:, daily_rate:, multiplier: nil)
      new(record: record, daily_rate: daily_rate, multiplier: multiplier).calculate
    end

    def initialize(record:, daily_rate:, multiplier: nil)
      @record      = record
      @daily_rate  = daily_rate.to_f
      @multiplier  = multiplier&.to_f
    end

    def calculate
      shift = @record.shift_assignment&.shift
      return zero_result unless shift

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

      [ worked - scheduled, 0 ].max
    end

    def overtime_pay(shift, overtime_mins)
      shift_hours = shift.duration_minutes.to_f / 60
      return 0.0 if shift_hours.zero?

      hourly_rate    = @daily_rate / shift_hours
      overtime_hours = overtime_mins / 60.0
      multiplier     = @multiplier || shift.overtime_rate_multiplier.to_f

      (hourly_rate * overtime_hours * multiplier).round(2)
    end

    def zero_result
      OvertimeResult.new(overtime_minutes: 0, overtime_pay: 0.0)
    end
  end
end
