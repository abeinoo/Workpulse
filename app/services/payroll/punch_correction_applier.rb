module Payroll
  # After a PunchCorrection is applied and the AttendanceRecord has been
  # updated and recomputed, this service updates any open PayrollEntry line
  # items that were derived from that attendance record.
  #
  # Mirrors PermissionApplier but recalculates from the record's new derived
  # minutes rather than subtracting an approved permission offset.
  class PunchCorrectionApplier
    def self.call(request:, record:)
      new(request, record).call
    end

    def initialize(request, record)
      @request = request
      @record  = record
    end

    def call
      period = open_period_covering(@record.work_date)
      return unless period

      entry = PayrollEntry.find_by(payroll_period: period, user: @request.user)
      return unless entry

      ActiveRecord::Base.transaction do
        update_penalty_item(entry, "late_penalty",        @record.late_minutes.to_i)
        update_penalty_item(entry, "early_leave_penalty", @record.early_leave_minutes.to_i)
        entry.recalculate_totals!
      end
    end

    private

    def open_period_covering(date)
      PayrollPeriod.where(
        business:     @request.user.business,
        period_month: date.month,
        period_year:  date.year
      ).where.not(status: %w[finalized paid]).first
    end

    def update_penalty_item(entry, item_type, new_minutes)
      line_item = entry.payroll_line_items.find_by(
        source_type: "AttendanceRecord",
        source_id:   @record.id,
        item_type:   item_type
      )
      return unless line_item

      if new_minutes == 0
        line_item.destroy!
        return
      end

      business   = @request.user.business
      daily_rate = Salary::DailyRateCalculator.for(
        user:     @request.user,
        business: business,
        date:     entry.payroll_period.period_start
      ).daily_rate

      new_amount = if item_type == "late_penalty"
        result = Attendance::PenaltyCalculator.calculate(
          record:                @record,
          daily_salary:          daily_rate,
          late_minutes_override: new_minutes
        )
        -result.late_penalty
      else
        result = Attendance::PenaltyCalculator.calculate(
          record:                       @record,
          daily_salary:                 daily_rate,
          early_leave_minutes_override: new_minutes
        )
        -result.early_leave_penalty
      end

      if new_amount.round(2) == 0.0
        line_item.destroy!
      else
        line_item.update!(amount: new_amount.round(2), original_minutes: new_minutes)
      end
    end
  end
end
