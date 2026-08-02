module Employee
  # Creates or updates a user's EmployeeInsuranceProfile — the single entry
  # point for editing insurance configuration, per the "services own mutation"
  # architecture rule. Loads the target user by id (never a pre-loaded
  # controller-side object) to avoid autosaving a blank association.
  class InsuranceProfileUpdater
    include AuditLoggable

    Result = Struct.new(:ok, :profile, :error, keyword_init: true) { def ok? = ok }

    def self.call(user_id:, actor:, attrs:)
      new(user_id: user_id, actor: actor, attrs: attrs).call
    end

    def initialize(user_id:, actor:, attrs:)
      @user_id = user_id
      @actor   = actor
      @attrs   = attrs
    end

    def call
      user = User.where(business_id: @actor.business_id).find(@user_id)
      profile = EmployeeInsuranceProfile.find_or_initialize_by(user: user)
      was_new = profile.new_record?
      before  = profile.attributes.slice(*%w[insured employee_contribution_amount employer_contribution_amount
                                              insurance_start_date insurance_end_date insurance_number])

      profile.assign_attributes(@attrs)
      profile.business   ||= user.business
      profile.created_by ||= @actor

      ActiveRecord::Base.transaction do
        profile.save!

        log_audit(
          actor:     @actor,
          auditable: profile,
          action:    was_new ? "insurance_profile_created" : "insurance_profile_updated",
          changes:   { before: before, after: profile.attributes.slice(*before.keys) }
        )
      end

      Result.new(ok: true, profile: profile)
    rescue ActiveRecord::RecordInvalid => e
      Result.new(ok: false, profile: e.record, error: e.record.errors.full_messages.join(", "))
    rescue ActiveRecord::RecordNotFound => e
      Result.new(ok: false, error: e.message)
    end
  end
end
