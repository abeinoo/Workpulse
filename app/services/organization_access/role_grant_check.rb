module OrganizationAccess
  # Escalation guard shared by CreateRole and UpdateRole (formerly
  # Admin::PermissionRolesController#grants_ungrantable_permissions?).
  #
  # A non-owner may only add permissions they hold themselves, and may not grant
  # a permission at a scope broader than their own (PermissionGrants). Runs after
  # validation so role_type defaults and normalization are included; permissions
  # the role already had are not re-checked. Adds the errors to the role and
  # returns true when the change must be refused.
  module RoleGrantCheck
    module_function

    def violations?(actor:, role:, previous_permissions:)
      role.validate
      denied    = PermissionGrants.ungrantable(actor, role.permissions - previous_permissions)
      overbroad = PermissionGrants.overbroad_scopes(actor, role)
      return false if denied.empty? && overbroad.empty?

      if denied.any?
        role.errors.add(:permissions, I18n.t("admin.permission_roles.errors.cannot_grant", permissions: denied.join(", ")))
      end
      if overbroad.any?
        role.errors.add(:permission_scopes, I18n.t("admin.permission_roles.errors.scope_too_broad", permissions: overbroad.join(", ")))
      end
      true
    end
  end
end
