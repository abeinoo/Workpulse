module OrganizationAccess
  # Updates a PermissionRole of the actor's business, loaded here by id (a role
  # of another business raises ActiveRecord::RecordNotFound). The actor must be
  # allowed to manage the role as it stands (PermissionRolePolicy#update?) and
  # may not add permissions or scopes beyond their own (RoleGrantCheck).
  # Role changes are not audited (plan D1).
  class UpdateRole
    Result = Struct.new(:ok, :record, :error, keyword_init: true) { def ok? = ok }

    def initialize(role_id, actor:, attributes:)
      @role_id    = role_id
      @actor      = actor
      @attributes = attributes
    end

    def call
      role = PermissionRole.where(business_id: @actor.business_id).find(@role_id)
      return Result.new(ok: false, record: role, error: :not_authorized) unless PermissionRolePolicy.new(@actor, role).update?

      previous_permissions = role.permissions.dup
      role.assign_attributes(@attributes)
      return Result.new(ok: false, record: role, error: :invalid) if RoleGrantCheck.violations?(actor: @actor, role: role, previous_permissions: previous_permissions)
      return Result.new(ok: false, record: role, error: :invalid) unless role.save

      Result.new(ok: true, record: role)
    end
  end
end
