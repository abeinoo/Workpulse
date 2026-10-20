module Salary
  # Creates a new SalaryProfile for a user and deactivates all previous ones.
  # A user should only ever have one active profile at a time.
  # Historical profiles are preserved (never deleted) for payroll audit.
  # The single entry point for entering a salary profile (admin and API).
  #
  # Audited as "create" on the new profile, in the same transaction: who, for
  # which employee, where (source), the effective date and the profiles it
  # superseded — never the amounts.
  class ProfileUpdater
    include AuditLoggable

    # On failure `profile` is the invalid record (for re-rendering a form).
    Result = Struct.new(:success, :profile, :errors, keyword_init: true) do
      def success? = success
    end

    SOURCES = %w[admin api].freeze

    def self.call(user:, params:, actor: nil, source: nil)
      new(user: user, params: params, actor: actor, source: source).call
    end

    def initialize(user:, params:, actor: nil, source: nil)
      @user   = user
      @params = params.to_h.symbolize_keys
      @actor  = actor || user
      @source = source
    end

    def call
      raise ArgumentError, "unknown salary profile source: #{@source}" if @source && !SOURCES.include?(@source)

      profile = ActiveRecord::Base.transaction do
        superseded_ids = @user.salary_profiles.where(active: true).pluck(:id)
        @user.salary_profiles.where(active: true).update_all(active: false)
        @user.salary_profiles.create!(@params.merge(active: true)).tap do |created|
          log_audit(actor: @actor, auditable: created, action: "create",
                    metadata: { source: @source, user_id: @user.id, salary_type: created.salary_type,
                                effective_from: created.effective_from.iso8601,
                                superseded_profile_ids: superseded_ids })
        end
      end

      recalculate_open_periods

      Result.new(success: true, profile: profile)
    rescue ActiveRecord::RecordInvalid => e
      Result.new(success: false, profile: e.record, errors: e.record.errors.full_messages)
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
