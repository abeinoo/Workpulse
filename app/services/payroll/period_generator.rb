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
        # Destroy obligation snapshots BEFORE entries: the before_destroy callback
        # on ObligationDeduction restores each obligation's remaining_amount so the
        # balance is accurate when ObligationDeductor runs again during regeneration.
        ObligationDeduction.where(payroll_period: period).destroy_all
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
      period_start = Date.new(@year.to_i, @month.to_i, 1)
      period_end   = period_start.end_of_month

      # Inactive employees must still appear when they have payroll-relevant
      # activity in the period: attendance records, payroll adjustments, or
      # active advances with a remaining balance that must be deducted.
      with_attendance = AttendanceRecord
        .active
        .where(user_id: @business.users.select(:id), work_date: period_start..period_end)
        .select(:user_id)

      with_adjustments = PayrollAdjustment
        .where(business: @business, period_year: @year.to_i, period_month: @month.to_i)
        .select(:user_id)

      with_advances = Advance
        .active
        .where(user_id: @business.users.select(:id))
        .where("remaining_amount > 0")
        .select(:user_id)

      @business.users
        .where(active: true)
        .or(@business.users.where(id: with_attendance))
        .or(@business.users.where(id: with_adjustments))
        .or(@business.users.where(id: with_advances))
        .includes(:salary_profiles)
    end

    def validate_month!
      raise ArgumentError, "Invalid month: #{@month}" unless (1..12).cover?(@month.to_i)
      raise ArgumentError, "Invalid year: #{@year}"  unless @year.to_i > 2000
    end
  end
end
