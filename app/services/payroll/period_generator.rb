module Payroll
  # Generates or regenerates a company-wide payroll period for a given month.
  # One period per business per month — no branch scoping.
  # Idempotent: regenerating a draft period clears existing entries first.
  # Raises if the period has already advanced past draft.
  class PeriodGenerator
    def self.call(business:, year:, month:, generated_by:)
      new(business: business, year: year, month: month, generated_by: generated_by).call
    end

    def initialize(business:, year:, month:, generated_by:)
      @business     = business
      @year         = year
      @month        = month
      @generated_by = generated_by
    end

    def call
      validate_month!

      ActiveRecord::Base.transaction do
        period = find_or_build_period
        period.payroll_entries.destroy_all  # clear stale entries on regeneration
        period.save!

        users_for_payroll.each do |user|
          EntryCalculator.call(period: period, user: user, business: @business)
        end

        period.update!(generated_at: Time.current)
        period
      end
    end

    private

    def find_or_build_period
      existing = PayrollPeriod.find_by(business: @business, period_year: @year, period_month: @month)

      if existing
        raise "Cannot regenerate a payroll that is already #{existing.status}" unless existing.draft?
        existing.assign_attributes(working_days: @business.working_days_per_month, generated_by: @generated_by)
        existing
      else
        PayrollPeriod.new(
          business:     @business,
          period_year:  @year,
          period_month: @month,
          working_days: @business.working_days_per_month,
          generated_by: @generated_by
        )
      end
    end

    def users_for_payroll
      @business.users.where(active: true).includes(:salary_profiles)
    end

    def validate_month!
      raise ArgumentError, "Invalid month: #{@month}" unless (1..12).cover?(@month.to_i)
      raise ArgumentError, "Invalid year: #{@year}"  unless @year.to_i > 2000
    end
  end
end
