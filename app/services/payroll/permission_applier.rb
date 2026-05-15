module Payroll
  # When an EmployeeRequest of type late_permission or early_leave is approved,
  # retroactively updates any existing PayrollLineItem that was built from the
  # same AttendanceRecord — so employees are not double-penalised just because
  # payroll was generated before their request was approved.
  #
  # Only touches periods that are still open (not finalized or paid).
  class PermissionApplier
    def self.call(request)
      new(request).call
    end

    def initialize(request)
      @request = request
    end

    def call
      return unless @request.late_permission? || @request.early_leave?
      return unless @request.approved? && @request.duration_minutes.to_i > 0

      attendance = AttendanceRecord.includes(shift_assignment: { shift: :penalty_rules })
                                   .find_by(user: @request.user, work_date: @request.requested_for_date)
      return unless attendance

      period = open_period_covering(attendance.work_date)
      return unless period

      entry = PayrollEntry.find_by(payroll_period: period, user: @request.user)
      return unless entry

      item_type = @request.late_permission? ? "late_penalty" : "early_leave_penalty"
      line_item = entry.payroll_line_items.find_by(
        source_type: "AttendanceRecord",
        source_id:   attendance.id,
        item_type:   item_type
      )
      return unless line_item

      apply!(entry, line_item, attendance)
    end

    private

    def open_period_covering(date)
      PayrollPeriod.where(
        business:     @request.user.business,
        period_month: date.month,
        period_year:  date.year
      ).where.not(status: %w[finalized paid]).first
    end

    def apply!(entry, line_item, attendance)
      approved_mins  = @request.duration_minutes.to_i
      raw_minutes    = line_item.original_minutes ||
                       (@request.late_permission? ? attendance.late_minutes.to_i : attendance.early_leave_minutes.to_i)
      effective_mins = [ raw_minutes - approved_mins, 0 ].max

      business   = @request.user.business
      daily_rate = Salary::DailyRateCalculator.for(
        user:     @request.user,
        business: business,
        date:     entry.payroll_period.period_start
      ).daily_rate

      new_amount = if @request.late_permission?
        penalty = Attendance::PenaltyCalculator.calculate(
          record:                attendance,
          daily_salary:          daily_rate,
          late_minutes_override: effective_mins
        )
        -penalty.late_penalty
      else
        penalty = Attendance::PenaltyCalculator.calculate(
          record:                       attendance,
          daily_salary:                 daily_rate,
          early_leave_minutes_override: effective_mins
        )
        -penalty.early_leave_penalty
      end

      ActiveRecord::Base.transaction do
        if new_amount.round(2) == 0.0
          line_item.destroy!
        else
          line_item.update!(
            amount:             new_amount.round(2),
            original_minutes:   raw_minutes,
            permission_minutes: approved_mins
          )
        end
        entry.recalculate_totals!
      end
    end
  end
end
