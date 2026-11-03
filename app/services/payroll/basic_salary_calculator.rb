module Payroll
  # Basic salary for one payroll entry, priced portion by portion — one portion
  # per salary profile in force during the period (Salary::ProfileTimeline
  # segments) — plus the breakdown persisted on PayrollEntry#salary_breakdown.
  #
  #   daily portion:   base_amount × complete attendance days in the portion
  #   monthly portion: one of two proration rules, chosen per entry —
  #
  #   1. Calendar days (salaried since the period's first day):
  #        base_amount × calendar days in the portion / calendar days in the period
  #      One monthly profile for the whole period is therefore paid exactly its
  #      base_amount.
  #
  #   2. Starter working days (the employee's FIRST profile takes effect after
  #      the period's first day) — the established mid-period starter rule:
  #        daily rate × W   (daily rate = base_amount / working_days_per_month
  #                          to 4 decimals, as Salary::DailyRateCalculator)
  #      where W = the starter's prorated working days (EntryCalculator#
  #      working_days_for: the period's working days × window days / period
  #      days, rounded, at least 1) and the window runs from the first effective
  #      day to the period end. When the starter's salary also changes within the
  #      period, W is shared between the window's portions by calendar days:
  #        daily rate × W × portion days / window days
  #      — with a single profile, exactly the established rule.
  #
  # Days before the employee's first profile belong to no portion and earn
  # nothing.
  #
  # Rounding policy: every portion is computed exactly (Rational, from the
  # profile's decimal base_amount — never Float); the TOTAL is rounded once, to
  # cents, half up. The portions' stored amounts are that total apportioned in
  # cents by largest remainder (earlier portion first on a tie), so they always
  # sum exactly to base_salary — no rounding drift between portions.
  class BasicSalaryCalculator
    BREAKDOWN_VERSION = 1
    ROUNDING = "total_half_up_cents;portions_largest_remainder".freeze

    Result = Struct.new(:amount, :breakdown, keyword_init: true)

    PRORATION_CALENDAR_DAYS = "calendar_days".freeze
    PRORATION_STARTER       = "starter_working_days".freeze

    # working_days: the entry's working days (for a starter, W above).
    def self.call(period:, segments:, records:, business:, working_days:)
      new(period: period, segments: segments, records: records, business: business, working_days: working_days).call
    end

    def initialize(period:, segments:, records:, business:, working_days:)
      @period       = period
      @segments     = segments
      @records      = records
      @business     = business
      @working_days = working_days
    end

    def call
      exact  = @segments.map { |segment| exact_amount(segment) }
      total  = (exact.sum * 100).round(half: :up)
      shares = apportion_cents(exact, total)

      Result.new(amount: BigDecimal(total) / 100, breakdown: breakdown(shares, total))
    end

    def period_days
      @period_days ||= (@period.period_end - @period.period_start).to_i + 1
    end

    # The employee's first profile takes effect after the period's first day.
    def starter?
      @segments.first.starts_on > @period.period_start
    end

    private

    def exact_amount(segment)
      base = segment.profile.base_amount.to_r
      if segment.profile.daily?
        base * days_worked_in(segment)
      elsif starter?
        starter_daily_rate(segment.profile) * @working_days * segment.days / window_days
      else
        base * segment.days / period_days
      end
    end

    # The established starter rule prices with the profile's daily rate as
    # Salary::DailyRateCalculator defines it (base / working_days_per_month,
    # rounded to 4 decimals) — taken exactly, so the result matches it to the cent.
    def starter_daily_rate(profile)
      (profile.base_amount.to_r / @business.working_days_per_month).round(4, half: :up)
    end

    # Calendar days from the first salaried day to the period end.
    def window_days
      @window_days ||= (@period.period_end - @segments.first.starts_on).to_i + 1
    end

    def days_worked_in(segment)
      @records.count { |r| r.complete? && segment.cover?(r.work_date) }
    end

    # Exact amounts → integer cents summing to `total` (largest remainder).
    def apportion_cents(exact, total)
      cents    = exact.map { |amount| amount * 100 }
      floors   = cents.map(&:floor)
      leftover = total - floors.sum
      cents.each_index.sort_by { |i| [ -(cents[i] - floors[i]), i ] }.first(leftover).each { |i| floors[i] += 1 }
      floors
    end

    # Starter entries also record the inputs of rule 2 so their monthly portions
    # can be explained (additive keys; calendar-day entries are unchanged).
    def breakdown(shares, total)
      {
        "version"              => BREAKDOWN_VERSION,
        "rounding"             => ROUNDING,
        "period_start"         => @period.period_start.iso8601,
        "period_end"           => @period.period_end.iso8601,
        "period_calendar_days" => period_days,
        "proration"            => starter? ? PRORATION_STARTER : PRORATION_CALENDAR_DAYS,
        **starter_inputs,
        "total"                => money(total),
        "portions"             => @segments.each_with_index.map do |segment, i|
          {
            "salary_profile_id" => segment.profile.id,
            "salary_type"       => segment.profile.salary_type,
            "base_amount"       => money((segment.profile.base_amount * 100).to_i),
            "starts_on"         => segment.starts_on.iso8601,
            "ends_on"           => segment.ends_on.iso8601,
            "calendar_days"     => segment.days,
            "days_worked"       => days_worked_in(segment),
            "amount"            => money(shares[i])
          }
        end
      }
    end

    def starter_inputs
      return {} unless starter?

      {
        "salary_starts_on"       => @segments.first.starts_on.iso8601,
        "salary_window_days"     => window_days,
        "starter_working_days"   => @working_days,
        "working_days_per_month" => @business.working_days_per_month
      }
    end

    # Integer cents → "1234.56" (decimal string: JSON numbers are floats).
    def money(cents)
      format("%<units>d.%<cents>02d", units: cents / 100, cents: cents % 100)
    end
  end
end
