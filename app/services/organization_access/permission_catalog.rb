module OrganizationAccess
  # Read-only Organization & Access boundary over the permission catalogue for
  # callers OUTSIDE the domain (PermissionRole pilot, Step 2 — see
  # docs/architecture/permission-role-migration-plan.md, interface I3).
  #
  # Delegates to PermissionRole::PERMISSION_GROUPS, which stays the single
  # source of truth: nothing is copied here. Step 3 will move the Laundry
  # workspace gate and EmployeeDataRequestPolicy#index? onto this interface.
  module PermissionCatalog
    module_function

    # The permission names (Strings) of a permission group — the very array
    # PermissionRole::PERMISSION_GROUPS holds (returned as-is, not copied).
    # Raises KeyError for an unknown group instead of returning nil.
    def group(name)
      PermissionRole::PERMISSION_GROUPS.fetch(name.to_sym)
    end
  end
end
