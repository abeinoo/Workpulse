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

        # An update overwrites contribution amounts in place, so its entry is
        # the only record of the previous values: fail-closed (BUG-003). A new
        # profile records its own creator: fail-open.
        audit = { actor: @actor, auditable: profile,
                  action:  was_new ? "insurance_profile_created" : "insurance_profile_updated",
                  changes: { before: before, after: profile.attributes.slice(*before.keys) } }
        was_new ? log_audit(**audit) : log_audit!(**audit)
      end

      recalculate_open_periods(user)

      Result.new(ok: true, profile: profile)
    rescue ActiveRecord::RecordInvalid => e
      Result.new(ok: false, profile: e.record, error: e.record.errors.full_messages.join(", "))
    rescue ActiveRecord::RecordNotFound => e
      Result.new(ok: false, error: e.message)
    rescue AuditLoggable::AuditWriteFailed
      Result.new(ok: false, profile: profile, error: I18n.t("audit_log.errors.write_failed"))
    end

    private

    # An insurance change should be reflected in every currently editable
    # period, not just the next full generation — mirrors the
    # attendance-triggered recalculation path. Payroll owns that, behind the
    # Workforce contract Employee::InsuranceProfileEffects. Called after the
    # commit; never allowed to fail the insurance profile change itself.
    def recalculate_open_periods(user)
      Employee::InsuranceProfileEffects.profile_changed(user: user, actor: @actor)
    rescue => e
      Rails.logger.error("[Employee::InsuranceProfileUpdater] payroll recalc failed user=#{user.id}: #{e.class}: #{e.message}")
    end
  end
end
