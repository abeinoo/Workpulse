module OrganizationAccess
  # Deletes a PermissionRole of the actor's business, loaded here by id (a role
  # of another business raises ActiveRecord::RecordNotFound). The actor must be
  # allowed to manage the role (PermissionRolePolicy#destroy?), and a role that
  # still has users is never deleted. Role changes are not audited (plan D1).
  class DeleteRole
    Result = Struct.new(:ok, :record, :error, keyword_init: true) { def ok? = ok }

    def initialize(role_id, actor:)
      @role_id = role_id
      @actor   = actor
    end

    def call
      role = PermissionRole.where(business_id: @actor.business_id).find(@role_id)
      return Result.new(ok: false, record: role, error: :not_authorized) unless PermissionRolePolicy.new(@actor, role).destroy?
      return Result.new(ok: false, record: role, error: :has_users) if role.users.any?

      role.destroy
      Result.new(ok: true, record: role)
    end
  end
end
