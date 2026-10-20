module Salary
  # Corrects a salary profile in place (admin edit, API update) — the only
  # path for changing an existing profile. Authorization (SalaryProfilePolicy
  # #update?: the current, still-active profile of an employee the actor may
  # manage and view, never their own) stays with the caller, which passes the
  # profile's id; the profile is loaded here, inside the actor's business.
  #
  # Audited as "update" on the profile, in the same transaction, naming the
  # corrected fields — never their values. A submission that changes nothing
  # writes nothing.
  class ProfileCorrector
    include AuditLoggable

    Result = Struct.new(:success, :profile, :errors, keyword_init: true) do
      def success? = success
    end

    SOURCES = %w[admin api].freeze

    def self.call(profile_id:, attributes:, actor:, source:)
      new(profile_id: profile_id, attributes: attributes, actor: actor, source: source).call
    end

    def initialize(profile_id:, attributes:, actor:, source:)
      @profile_id = profile_id
      @attributes = attributes.to_h
      @actor      = actor
      @source     = source
    end

    def call
      raise ArgumentError, "unknown salary profile source: #{@source}" unless SOURCES.include?(@source)

      profile = SalaryProfile.for_business(@actor.business).find(@profile_id)
      profile.assign_attributes(@attributes)
      changed_fields = profile.changed

      if changed_fields.any?
        ActiveRecord::Base.transaction do
          profile.save!
          log_audit(actor: @actor, auditable: profile, action: "update",
                    metadata: { source: @source, user_id: profile.user_id, changed_fields: changed_fields })
        end
        recalculate_open_periods(profile.user)
      end

      Result.new(success: true, profile: profile)
    rescue ActiveRecord::RecordInvalid => e
      Result.new(success: false, profile: e.record, errors: e.record.errors.full_messages)
    end

    private

    # Same as Salary::ProfileUpdater: every currently editable period reflects
    # the correction; never allowed to fail the correction itself.
    def recalculate_open_periods(user)
      Payroll::EntryRecalculator.recalculate_all_open_periods_for(user: user, triggered_by: @actor)
    rescue => e
      Rails.logger.error("[Salary::ProfileCorrector] payroll recalc failed user=#{user.id}: #{e.class}: #{e.message}")
    end
  end
end
