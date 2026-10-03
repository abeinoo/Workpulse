module OrganizationAccess
  # Organization & Access boundary for reading a user's permissions from
  # outside the domain (PermissionRole pilot, Step 2 — see
  # docs/architecture/permission-role-migration-plan.md, interface I5).
  #
  # Permission CHECKS stay on User#can? / User#scope_for, the existing
  # cross-domain interface (I1/I2); they are not duplicated here.
  module Authorization
    module_function

    # The permissions explicitly granted through the user's role — exactly what
    # the API login payload exposes today (Api::V1::SessionsController, Step 3
    # target). The owner holds every permission but has no role, so this is []
    # for the owner, as it is for a user without a role.
    def granted_permissions(user)
      user.permission_role&.permissions || []
    end
  end
end
