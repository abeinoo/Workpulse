module Payroll
  # Scheduled auto-generation of payroll periods for a single business.
  # Called daily by Payroll::AutoGenerateJob — no-ops unless today matches
  # the business's configured generation day in its own timezone.
  #
  # Returns a Result so the job can log outcomes without raising.
  class AutoGenerator
    Result = Struct.new(:skipped, :period, :error, keyword_init: true) do
      def success? = error.nil? && !skipped
      def skipped? = skipped
    end

    def self.call(business:, actor: nil)
      new(business: business, actor: actor).call
    end

    def initialize(business:, actor: nil)
      @business = business
      @actor    = actor
    end

    def call
      return Result.new(skipped: true) unless should_generate?

      target_year  = generation_target_date.year
      target_month = generation_target_date.month

      # Guard: period already exists (finalized/paid) — never overwrite
      existing = PayrollPeriod.find_by(
        business_id:   @business.id,
        period_year:   target_year,
        period_month:  target_month
      )
      if existing&.locked?
        return Result.new(skipped: true)
      end

      period = PeriodGenerator.call(
        business:      @business,
        year:          target_year,
        month:         target_month,
        generated_by:  system_actor
      )

      PayrollAuditLog.create!(
        payroll_period: period,
        actor:          system_actor,
        action_type:    "generated",
        metadata:       { auto: true, trigger: "scheduled" }.to_json
      )

      Result.new(skipped: false, period: period)
    rescue StandardError => e
      Result.new(skipped: false, error: e.message)
    end

    private

    def should_generate?
      return false unless @business.auto_payroll_enabled?
      today_in_tz.day == @business.payroll_auto_generate_day
    end

    def today_in_tz
      Time.current.in_time_zone(@business.timezone_object).to_date
    end

    # Target = the previous calendar month when generating early in the month,
    # or the current month when generating mid/late.
    # Convention: generate on day N for the current month's payroll.
    # (Generate day 1 = generates for current month at start.)
    def generation_target_date
      today_in_tz.beginning_of_month
    end

    def system_actor
      @system_actor ||= @actor || @business.owner
    end
  end
end
