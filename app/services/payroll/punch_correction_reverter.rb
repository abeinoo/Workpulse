module Payroll
  # After a cancelled PunchCorrection's AttendanceRecord has been restored and
  # recomputed, brings the penalty line items of the employee's entry in the
  # (open) period back in line with it: updates them, RECREATES a line the
  # correction had deleted, or deletes one the restored minutes no longer
  # justify, then recalculates the totals.
  #
  # Moved unchanged from Requests::Canceller#rollback_punch_payroll /
  # #restore_penalty_line_item (Pilot 10 M4-2); called by
  # Attendance::PunchCorrectionEffects.correction_cancelled with the period it
  # has already row-locked and checked. Payroll::PermissionReverter keeps its own
  # copies of the period / rate / penalty helpers (a separate follow-up).
  class PunchCorrectionReverter
    def self.call(request:, record:, period:)
      new(request, record, period).call
    end

    def initialize(request, record, period)
      @request = request
      @record  = record
      @period  = period
    end

    def call
      return if @period.locked?

      entry = PayrollEntry.find_by(payroll_period: @period, user: @request.user)
      return unless entry

      daily_rate = daily_rate_for(entry)

      restore_penalty_line_item(entry, "late_penalty",        @record.late_minutes.to_i,        daily_rate)
      restore_penalty_line_item(entry, "early_leave_penalty", @record.early_leave_minutes.to_i, daily_rate)
      entry.recalculate_totals!
    end

    private

    def restore_penalty_line_item(entry, item_type, raw_minutes, daily_rate)
      line_item = entry.payroll_line_items.find_by(
        source_type: "AttendanceRecord",
        source_id:   @record.id,
        item_type:   item_type
      )

      if raw_minutes == 0
        line_item&.destroy!
        return
      end

      full_amount = compute_penalty(daily_rate, item_type, raw_minutes)

      if full_amount.round(2) == 0.0
        line_item&.destroy!
      elsif line_item
        line_item.update!(amount: full_amount.round(2), original_minutes: raw_minutes)
      else
        type_label = item_type == "late_penalty" ? "Late arrival" : "Early leave"
        entry.payroll_line_items.create!(
          item_type:        item_type,
          amount:           full_amount.round(2),
          description:      "#{type_label} #{@record.work_date}",
          source_type:      "AttendanceRecord",
          source_id:        @record.id,
          original_minutes: raw_minutes
        )
      end
    end

    def daily_rate_for(entry)
      Salary::DailyRateCalculator.for(
        user:     @request.user,
        business: @request.user.business,
        date:     entry.payroll_period.period_start
      ).daily_rate
    end

    def compute_penalty(daily_rate, item_type, minutes)
      if item_type == "late_penalty"
        result = Attendance::PenaltyCalculator.calculate(
          record:                @record,
          daily_salary:          daily_rate,
          late_minutes_override: minutes
        )
        -result.late_penalty
      else
        result = Attendance::PenaltyCalculator.calculate(
          record:                       @record,
          daily_salary:                 daily_rate,
          early_leave_minutes_override: minutes
        )
        -result.early_leave_penalty
      end
    end
  end
end
