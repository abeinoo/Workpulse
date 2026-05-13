module Salary
  # Converts a SalaryProfile into per-day and per-hour rates.
  # Always uses the profile that was active on `date`, not necessarily today,
  # so payroll generation for past months stays accurate.
  class DailyRateCalculator
    def self.for(user:, business:, date: Date.current)
      new(user: user, business: business, date: date)
    end

    def initialize(user:, business:, date:)
      @user     = user
      @business = business
      @date     = date
    end

    # Returns the effective daily wage as a Float.
    def daily_rate
      return 0.0 unless profile

      if profile.monthly?
        (profile.base_amount.to_f / @business.working_days_per_month).round(4)
      else
        profile.base_amount.to_f
      end
    end

    # Returns the effective monthly wage as a Float (useful for display).
    def monthly_equivalent
      return 0.0 unless profile

      if profile.monthly?
        profile.base_amount.to_f
      else
        (profile.base_amount.to_f * @business.working_days_per_month).round(2)
      end
    end

    # Hourly rate derived from the shift duration.
    # shift.duration_minutes must return a positive number.
    def hourly_rate(shift)
      shift_hours = shift.duration_minutes.to_f / 60
      return 0.0 if shift_hours.zero?

      (daily_rate / shift_hours).round(4)
    end

    def profile
      @profile ||= @user.salary_profiles
                        .where("effective_from <= ?", @date)
                        .order(effective_from: :desc, id: :desc)
                        .first
    end
  end
end
