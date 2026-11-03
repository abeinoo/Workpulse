module Salary
  # An employee's salary history as a timeline: which SalaryProfile is in force
  # on any date, and how a date range splits into the stretches each profile
  # covers. Payroll prices every day with the profile in force on that day, so
  # a salary change partway through a month is honoured from its effective date.
  #
  # The rule is SalaryProfile's (EFFECTIVE_ORDER): the profile with the latest
  # effective_from on or before the date; on a tie, the most recently entered.
  # A profile never applies before its effective_from — days before the first
  # profile have no salary, and a future-dated profile is never borrowed.
  #
  # Resolved in memory over the employee's profiles, loaded once (the preloaded
  # association when the caller included it), so pricing a month of attendance
  # costs no query per day.
  class ProfileTimeline
    # One stretch of consecutive days priced by a single profile.
    Segment = Struct.new(:profile, :starts_on, :ends_on, keyword_init: true) do
      def days = (ends_on - starts_on).to_i + 1
      def cover?(date) = date.between?(starts_on, ends_on)
    end

    def self.for(user)
      new(user.salary_profiles.to_a)
    end

    def initialize(profiles)
      # EFFECTIVE_ORDER: effective_from desc, then id desc.
      @profiles = profiles.sort_by { |p| [ p.effective_from, p.id.to_i ] }.reverse
    end

    # The profile in force on `date`, or nil before the first one takes effect.
    def profile_on(date)
      @profiles.find { |p| p.effective_from <= date }
    end

    # The stretches of from..to, in date order, each with the profile in force
    # throughout it. Days before the first profile belong to no segment.
    def segments(from, to)
      change_dates = @profiles.map(&:effective_from).select { |d| d > from && d <= to }
      starts = ([ from ] + change_dates).uniq.sort

      starts.each_with_index.filter_map do |starts_on, i|
        profile = profile_on(starts_on)
        next unless profile

        ends_on = starts[i + 1] ? starts[i + 1] - 1 : to
        Segment.new(profile: profile, starts_on: starts_on, ends_on: ends_on)
      end
    end
  end
end
