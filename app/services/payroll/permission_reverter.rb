module Payroll
  # The reverse of Payroll::PermissionApplier: when an approved late_permission or
  # early_leave EmployeeRequest is cancelled, puts the full attendance penalty
  # back on the payroll entry. Attendance & Payroll's side of the Workforce
  # contract Requests::PermissionPayrollEffects#permission_cancelled (moved from
  # Requests::Canceller#rollback_permission in Pilot 9 M4, behaviour unchanged).
  #
  # PermissionApplier may have modified or deleted the PayrollLineItem when the
  # request was approved, and EntryCalculator may have generated the entry with
  # a reduced penalty if payroll was built after approval. Either way the full
  # penalty is recalculated from the attendance record's CURRENT minutes and the
  # line item restored, recreated, or removed (zero penalty).
  #
  # Answers :reverted — reverted, or nothing to revert (not a permission, no
  # attendance record, no payroll period, no entry, no penalty minutes) — or
  # :refused when the covering payroll period is finalized or paid. Any other
  # failure raises (e.g. ActiveRecord::RecordInvalid on an invalid line item).
  # Never writes the attendance record.
  class PermissionReverter
    def self.call(request)
      new(request).call
    end

    def initialize(request)
      @request = request
    end

    def call
      return :reverted unless @request.late_permission? || @request.early_leave?

      attendance = AttendanceRecord.find_by(user: @request.user, work_date: @request.requested_for_date)
      return :reverted unless attendance

      period = covering_period
      return :reverted unless period # no period → PermissionApplier never ran
      return :refused if period.finalized? || period.paid?

      entry = PayrollEntry.find_by(payroll_period: period, user: @request.user)
      return :reverted unless entry # entry not yet generated → no line items to reverse

      item_type   = @request.late_permission? ? "late_penalty" : "early_leave_penalty"
      raw_minutes = @request.late_permission? ? attendance.late_minutes.to_i : attendance.early_leave_minutes.to_i
      return :reverted if raw_minutes == 0 # no penalty existed; nothing to restore

      full_amount = compute_penalty(attendance, daily_rate_for(entry), item_type, raw_minutes)
      line_item = entry.payroll_line_items.find_by(source_type: "AttendanceRecord", source_id: attendance.id,
                                                   item_type: item_type)

      if full_amount.round(2) == 0.0
        line_item&.destroy!
      elsif line_item
        line_item.update!(amount: full_amount.round(2), original_minutes: raw_minutes, permission_minutes: nil)
      else
        # PermissionApplier deleted the item (penalty → 0 after permission) or
        # EntryCalculator omitted it because effective minutes were 0 — recreate.
        type_label = @request.late_permission? ? "Late arrival" : "Early leave"
        entry.payroll_line_items.create!(
          item_type:        item_type,
          amount:           full_amount.round(2),
          description:      "#{type_label} #{attendance.work_date}",
          source_type:      "AttendanceRecord",
          source_id:        attendance.id,
          original_minutes: raw_minutes
        )
      end

      entry.recalculate_totals!
      :reverted
    end

    private

    # The period of the request's month (any status) — as the cancellation has
    # always looked it up.
    def covering_period
      PayrollPeriod.where(
        business:     @request.user.business,
        period_month: @request.requested_for_date.month,
        period_year:  @request.requested_for_date.year
      ).first
    end

    def daily_rate_for(entry)
      Salary::DailyRateCalculator.for(
        user:     @request.user,
        business: @request.user.business,
        date:     entry.payroll_period.period_start
      ).daily_rate
    end

    def compute_penalty(record, daily_rate, item_type, minutes)
      if item_type == "late_penalty"
        -Attendance::PenaltyCalculator.calculate(record: record, daily_salary: daily_rate,
                                                 late_minutes_override: minutes).late_penalty
      else
        -Attendance::PenaltyCalculator.calculate(record: record, daily_salary: daily_rate,
                                                 early_leave_minutes_override: minutes).early_leave_penalty
      end
    end
  end
end
