module Salary
  # Calculates the maximum salary advance an employee may request and how much
  # of that limit remains after existing outstanding advances are deducted.
  #
  # Monthly employees:
  #   ceiling = base_salary × percentage / 100
  #
  # Daily employees:
  #   ceiling = recent_earnings × percentage / 100
  #   where recent_earnings = base_salary from the most recent PayrollEntry, or,
  #   if no payroll entry exists yet, daily_rate × days_worked in the last 30 days.
  #
  # Outstanding advances (reduces available amount):
  #   - Active Advance records still being repaid (remaining_amount)
  #   - Pending / approved salary advance requests not yet disbursed
  #
  # Returns nil when no percentage limit is configured for the business.
  class AdvanceEligibilityCalculator
    # :basis — :monthly or :daily
    # :description_key — i18n suffix for the UI hint ("monthly_basis" | "daily_basis")
    # :earned_basis — the salary/earnings figure the percentage was applied to
    # :max_amount — ceiling before subtracting outstanding advances
    # :outstanding — already-committed advance balance
    # :available — how much the employee may still request
    Result = Struct.new(
      :basis, :description_key, :earned_basis,
      :max_amount, :outstanding, :available,
      keyword_init: true
    )

    def self.for(user:)
      new(user: user).result
    end

    def initialize(user:)
      @user     = user
      @business = user.business
    end

    def result
      percentage = @business.max_salary_advance_percentage
      return nil unless percentage.present?

      profile = SalaryProfile.current_for(@user)
      return nil unless profile

      if profile.monthly?
        earned_basis    = profile.base_amount.to_f
        basis           = :monthly
        description_key = "monthly_basis"
      else
        earned_basis    = recent_daily_earnings
        basis           = :daily
        description_key = "daily_basis"
      end

      max_amount  = (earned_basis * percentage.to_f / 100.0).round(2)
      outstanding = outstanding_advance_balance
      available   = [ max_amount - outstanding, 0.0 ].max.round(2)

      Result.new(
        basis:           basis,
        description_key: description_key,
        earned_basis:    earned_basis,
        max_amount:      max_amount,
        outstanding:     outstanding,
        available:       available
      )
    end

    private

    # For daily employees: the most recent payroll entry's base_salary is the
    # most accurate view of what they actually earned in a period. Falls back to
    # last-30-days attendance when no entry exists yet.
    def recent_daily_earnings
      last_entry = PayrollEntry
        .where(user: @user, salary_type: "daily")
        .order(created_at: :desc)
        .first

      return last_entry.base_salary.to_f if last_entry

      # Fallback: daily_rate × days with attendance in the last 30 days
      daily_rate  = Salary::DailyRateCalculator.for(
        user: @user, business: @business
      ).daily_rate
      worked_days = AttendanceRecord
        .where(user: @user)
        .where(work_date: 30.days.ago.to_date..Date.current)
        .where.not(status: "absent")
        .count

      (daily_rate * worked_days).round(2)
    end

    # Sum of:
    #   1. Remaining balance on active advances (already disbursed, still repaying)
    #   2. Amounts in pending / approved salary advance requests (committed but
    #      not yet disbursed, so no Advance record exists yet)
    def outstanding_advance_balance
      active_balance = Advance.active.for_user(@user).sum(:remaining_amount).to_f

      # EmployeeRequests that are pending/approved but have NOT been paid out yet
      # (once paid, their status becomes "paid" and an Advance record is created,
      # so they are captured by active_balance above — not double-counted).
      pending_balance = EmployeeRequest
        .where(user: @user, request_type: "salary_advance", status: %w[pending approved])
        .sum(:amount).to_f

      (active_balance + pending_balance).round(2)
    end
  end
end
