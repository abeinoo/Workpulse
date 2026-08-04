module Salary
  # Creates a new SalaryProfile for a user and deactivates all previous ones.
  # A user should only ever have one active profile at a time.
  # Historical profiles are preserved (never deleted) for payroll audit.
  class ProfileUpdater
    Result = Struct.new(:success, :profile, :errors, keyword_init: true) do
      def success? = success
    end

    def self.call(user:, params:, actor: nil)
      new(user: user, params: params, actor: actor).call
    end

    def initialize(user:, params:, actor: nil)
      @user   = user
      @params = params.to_h.symbolize_keys
      @actor  = actor || user
    end

    def call
      profile = ActiveRecord::Base.transaction do
        @user.salary_profiles.where(active: true).update_all(active: false)
        @user.salary_profiles.create!(@params.merge(active: true))
      end

      recalculate_open_periods

      Result.new(success: true, profile: profile)
    rescue ActiveRecord::RecordInvalid => e
      Result.new(success: false, errors: e.record.errors.full_messages)
    end

    private

    # A salary change should be reflected in every currently editable period,
    # not just the next full generation — mirrors the attendance-triggered
    # recalculation path. Never allowed to fail the salary profile change itself.
    def recalculate_open_periods
      Payroll::EntryRecalculator.recalculate_all_open_periods_for(user: @user, triggered_by: @actor)
    rescue => e
      Rails.logger.error("[Salary::ProfileUpdater] payroll recalc failed user=#{@user.id}: #{e.class}: #{e.message}")
    end
  end
end
