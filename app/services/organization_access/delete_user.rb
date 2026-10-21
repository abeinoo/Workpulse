module OrganizationAccess
  # Deletes a user of the actor's business, loaded here by id (another
  # business's user raises ActiveRecord::RecordNotFound). Authorization is the
  # caller's (UserPolicy#destroy?, as before).
  #
  # Employee history is never deleted with the user (F-A5): User's history
  # associations are dependent: :restrict_with_error, so a user with payroll,
  # advances, requests, attendance, salary, obligations, insurance or
  # performance records — or custody accounts — is refused (:has_history) and
  # nothing changes; deactivation is the way to retire such an employee. A row of
  # another table still referencing the user (a foreign key) refuses it the same
  # way (:linked_records) instead of raising.
  #
  # One transaction: the user row is locked first (FOR UPDATE, so no history row
  # can be inserted for it until this commits), then destroyed, then the
  # "delete_employee" audit is written with AuditLog.create! — an audit failure
  # rolls the deletion back (:audit_failed); a refused deletion writes no audit.
  class DeleteUser
    Result = Struct.new(:ok, :record, :error, keyword_init: true) { def ok? = ok }

    def initialize(user_id, actor:)
      @user_id = user_id
      @actor   = actor
    end

    def call
      user  = User.where(business_id: @actor.business_id).find(@user_id)
      error = nil

      ActiveRecord::Base.transaction do
        user.lock!
        details = audit_details(user)

        unless user.destroy
          error = :has_history
          raise ActiveRecord::Rollback
        end

        AuditLog.create!(
          actor:          @actor,
          business_id:    @actor.business_id,
          auditable_type: "User",
          auditable_id:   user.id,
          action:         "delete_employee",
          changes_json:   {},
          metadata:       details
        )
      end

      Result.new(ok: error.nil?, record: user, error: error)
    rescue ActiveRecord::InvalidForeignKey
      Result.new(ok: false, record: user, error: :linked_records)
    rescue ActiveRecord::RecordInvalid
      Result.new(ok: false, record: user, error: :audit_failed)
    end

    private

    # Captured before the row is gone: the audit is the only remaining record of
    # who was deleted.
    def audit_details(user)
      {
        user_id:       user.id,
        full_name:     user.full_name,
        email:         user.email,
        employee_code: user.employee_code,
        active:        user.active?
      }.compact
    end
  end
end
