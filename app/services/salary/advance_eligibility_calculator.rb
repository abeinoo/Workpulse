module Salary
  # Calculates the maximum salary advance an employee may request and how much
  # of that limit remains after existing outstanding advances are deducted.
  #
  # The ceiling is a percentage of the employee's salary basis, and the basis
  # depends on the SalaryProfile#salary_type — mirroring how
  # Payroll::EntryCalculator#base treats the two salary types:
  #
  #   daily:   earned_basis = daily_rate × complete days worked this cycle (up to today)
  #   monthly: earned_basis = profile.base_amount (the full configured monthly salary —
  #            not prorated by worked days; a salaried employee's entitlement doesn't
  #            depend on attendance the way a daily worker's does)
  #
  #   ceiling = earned_basis × percentage / 100
  #
  # This makes eligibility track actual earned entitlement and stay completely
  # independent of whether or when a PayrollEntry was generated/regenerated.
  #
  # Outstanding advances (reduces available amount):
  #   - Active Advance records still being repaid (remaining_amount)
  #   - Pending / approved salary advance requests not yet disbursed
  #
  # Returns nil when no percentage limit is configured for the business (i.e.
  # advances are unrestricted). When a percentage IS configured but the
  # employee has no active SalaryProfile, returns a Result with no_profile:
  # true and available: 0 — a real employee-data problem, not an unrestricted
  # limit, so callers must not treat it as "no limit configured".
  class AdvanceEligibilityCalculator
    # :basis — :monthly or :daily (nil when no_profile)
    # :description_key — i18n suffix for the UI hint ("monthly_basis" | "daily_basis")
    # :earned_basis — the salary/earnings figure the percentage was applied to
    # :max_amount — ceiling before subtracting outstanding advances
    # :outstanding — already-committed advance balance
    # :available — how much the employee may still request
    # :no_profile — true when the employee has no active SalaryProfile at all
    Result = Struct.new(
      :basis, :description_key, :earned_basis,
      :max_amount, :outstanding, :available, :no_profile,
      keyword_init: true
    ) { def no_profile? = !!no_profile }

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
      return no_profile_result unless profile

      earned_basis    = earned_salary_to_date(profile)
      basis           = profile.monthly? ? :monthly : :daily
      description_key = profile.monthly? ? "monthly_basis" : "daily_basis"

      max_amount  = (earned_basis * percentage.to_f / 100.0).round(2)
      outstanding = outstanding_advance_balance
      available   = [ max_amount - outstanding, 0.0 ].max.round(2)

      Result.new(
        basis:           basis,
        description_key: description_key,
        earned_basis:    earned_basis,
        max_amount:      max_amount,
        outstanding:     outstanding,
        available:       available,
        no_profile:      false
      )
    end

    private

    def no_profile_result
      Result.new(
        basis:           nil,
        description_key: "no_profile",
        earned_basis:    0.0,
        max_amount:      0.0,
        outstanding:     0.0,
        available:       0.0,
        no_profile:      true
      )
    end

    # Salary basis the percentage is applied to. Branches on salary_type, same
    # as Payroll::EntryCalculator#base:
    #   - monthly employees: the full configured base_amount, independent of
    #     worked days (a fixed monthly salary is earned regardless of punches).
    #   - daily employees: daily_rate × complete days worked this cycle so far,
    #     since a daily worker only earns for days actually worked.
    def earned_salary_to_date(profile)
      return profile.base_amount.to_f if profile.monthly?

      daily_rate = Salary::DailyRateCalculator.for(
        user: @user, business: @business
      ).daily_rate

      (daily_rate * complete_days_in_current_cycle).round(2)
    end

    # The payroll cycle is the calendar month (see PayrollPeriod#period_start /
    # #period_end). Count only days the employee actually completed both punches on,
    # bounded above by today so eligibility never anticipates future work.
    def complete_days_in_current_cycle
      AttendanceRecord
        .active
        .where(user: @user)
        .for_period(Date.current.beginning_of_month, Date.current)
        .to_a
        .count(&:complete?)
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
