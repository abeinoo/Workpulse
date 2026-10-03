module OrganizationAccess
  # Privilege-escalation guard for role management (OA-S1/S3, see
  # docs/architecture/organization-access-migration-readiness.md).
  #
  # Rules — the business owner is exempt from all of them:
  #   * A user may only grant permissions they hold themselves.
  #   * A user may only manage (edit, delete, assign, un-assign) roles whose
  #     permissions they hold — no one manages a role "above" their own.
  #   * Changing a user's role requires manage_roles, never targets the owner,
  #     and never targets the actor themselves.
  #
  # Callers resolve roles through current_user.business, so a role id from
  # another business never reaches these checks (and User validates it too).
  module PermissionGrants
    # Authority over other accounts, access and business configuration. Taking
    # control of an account (reset its password, deactivate it, change its login
    # or access) is equivalent to acquiring these, so an actor may only do it to
    # users whose administrative permissions are a subset of their own. This is a
    # deliberate minimum set; operational permissions (payroll, finance, …) are not
    # ranked here — see the "Remaining Security / Authorization Concerns" note.
    ADMINISTRATIVE_PERMISSIONS = %w[manage_roles manage_employees manage_settings manage_branches].freeze

    module_function

    def administrative_permissions(user)
      return ADMINISTRATIVE_PERMISSIONS if user.persisted? && user.owner?

      Array(user.permission_role&.permissions) & ADMINISTRATIVE_PERMISSIONS
    end

    # Privilege hierarchy: true when `actor`'s administrative authority covers
    # everything `target` holds. The owner covers everyone; nobody but the owner
    # covers the owner.
    def covers?(actor, target)
      return true if actor.owner?
      return false if target.persisted? && target.owner?

      (administrative_permissions(target) - administrative_permissions(actor)).empty?
    end

    def grantable_permissions(actor)
      return PermissionRole::ALL_PERMISSIONS if actor.owner?

      Array(actor.permission_role&.permissions)
    end

    # Permissions in `permissions` that `actor` may not grant.
    def ungrantable(actor, permissions)
      return [] if actor.owner?

      Array(permissions).map(&:to_s).reject(&:blank?) - grantable_permissions(actor)
    end

    # ── Scope breadth (narrow guard; not a full permission-scope model) ───────
    # A grant may not be broader than the actor's own authority for that
    # permission. Breadth order of the existing scope values:
    #   self < branch < area < business
    # A blank scope means "hierarchy default" (the branches and areas the holder
    # manages) and is ranked as `area` — never business-wide. The future model
    # should be permission + scope + business + branch (see the readiness doc).
    SCOPE_RANK = { "self" => 0, "branch" => 1, "area" => 2, "business" => 3 }.freeze
    DEFAULT_SCOPE_RANK = SCOPE_RANK["area"]

    def scope_rank(scope)
      SCOPE_RANK.fetch(PermissionRole.normalize_scope(scope).to_s, DEFAULT_SCOPE_RANK)
    end

    # Scopable permissions in `role` whose configured scope is broader than the
    # actor's own scope for that permission.
    def overbroad_scopes(actor, role)
      return [] if actor.owner? || role.nil?

      (Array(role.permissions) & PermissionRole::SCOPABLE_PERMISSIONS).select do |permission|
        scope_rank(role.scope_for(permission)) > scope_rank(actor.scope_for(permission))
      end
    end

    # nil (no role) is always manageable. A role is manageable only when the
    # actor holds all of its permissions at least as broadly as the role grants.
    def manageable_role?(actor, role)
      role.nil? || (ungrantable(actor, role.permissions).empty? && overbroad_scopes(actor, role).empty?)
    end

    def can_change_role?(actor:, target:, from:, to:)
      return false unless actor.can?(:manage_roles)
      # persisted?: User#owner? compares owner_id with id, which is nil == nil
      # for an unsaved user in a business that has no owner yet.
      return false if target.persisted? && target.owner?
      return false if target == actor

      manageable_role?(actor, from) && manageable_role?(actor, to)
    end
  end
end
