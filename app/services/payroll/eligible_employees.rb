module Payroll
  # The employees a payroll period is calculated for — one rule, used by
  # Payroll::PeriodGenerator (generation) and Payroll::PeriodRecalculator
  # (discovering employees who became eligible after generation, e.g. through
  # a salary profile entered later).
  #
  # Active employees, plus inactive ones with payroll-relevant activity in the
  # period: attendance records, payroll adjustments, or active advances with a
  # remaining balance that must be deducted. Being listed does not mean being
  # paid: Payroll::EntryCalculator writes no entry for an employee with no
  # salary profile in force on any day of the period.
  module EligibleEmployees
    def self.for(business:, year:, month:)
      period_start = Date.new(year.to_i, month.to_i, 1)
      period_end   = period_start.end_of_month

      with_attendance = AttendanceRecord
        .active
        .where(user_id: business.users.select(:id), work_date: period_start..period_end)
        .select(:user_id)

      with_adjustments = PayrollAdjustment
        .where(business: business, period_year: year.to_i, period_month: month.to_i)
        .select(:user_id)

      with_advances = Advance
        .active
        .where(user_id: business.users.select(:id))
        .where("remaining_amount > 0")
        .select(:user_id)

      business.users
        .where(active: true)
        .or(business.users.where(id: with_attendance))
        .or(business.users.where(id: with_adjustments))
        .or(business.users.where(id: with_advances))
    end
  end
end
