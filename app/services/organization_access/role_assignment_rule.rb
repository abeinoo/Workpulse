module OrganizationAccess
  # The single authoritative decision for changing a user's role (PermissionRole
  # pilot, Step 5 — risk R-H2). Used by both entry points: the role screen
  # (ChangeUserRole) and the employee form (Admin::UsersController#assign_role).
  #
  # The requested role is resolved inside the actor's business only — an unknown
  # or foreign role id is refused (OA-S2) — and the change must pass
  # PermissionGrants.can_change_role? (manage_roles; never self or the owner;
  # both the current and the new role within the actor's permissions and scopes
  # — OA-S3/S4/S5). A blank role id means "remove the role".
  module RoleAssignmentRule
    Decision = Struct.new(:allowed, :role, keyword_init: true) { def allowed? = allowed }

    module_function

    def decide(actor:, user:, role_id:)
      requested_id = role_id.presence&.to_i
      role = requested_id && actor.business.permission_roles.find_by(id: requested_id)
      return Decision.new(allowed: false, role: nil) if requested_id && role.nil?

      allowed = PermissionGrants.can_change_role?(actor: actor, target: user, from: user.permission_role, to: role)
      Decision.new(allowed: allowed, role: role)
    end
  end
end
