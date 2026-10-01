module OrganizationAccess
  # Creates a PermissionRole in the actor's business. The role is always built
  # through actor.business; the actor must be allowed to create roles
  # (PermissionRolePolicy) and may not grant permissions or scopes beyond their
  # own (RoleGrantCheck). Role changes are not audited (plan D1).
  class CreateRole
    Result = Struct.new(:ok, :record, :error, keyword_init: true) { def ok? = ok }

    def initialize(actor:, attributes:)
      @actor      = actor
      @attributes = attributes
    end

    def call
      role = @actor.business.permission_roles.new(@attributes)
      return Result.new(ok: false, record: role, error: :not_authorized) unless PermissionRolePolicy.new(@actor, role).create?
      return Result.new(ok: false, record: role, error: :invalid) if RoleGrantCheck.violations?(actor: @actor, role: role, previous_permissions: [])
      return Result.new(ok: false, record: role, error: :invalid) unless role.save

      Result.new(ok: true, record: role)
    end
  end
end
