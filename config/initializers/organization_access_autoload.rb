# Organization & Access models live in app/models/organization_access/ but keep
# their top-level constants (e.g. PermissionRole, table permission_roles): the
# directory is collapsed, so it groups files without adding a namespace. The
# OrganizationAccess:: boundary lives in app/services/organization_access/.
# See docs/architecture/permission-role-migration-plan.md, Step 7.
Rails.autoloaders.main.collapse(Rails.root.join("app/models/organization_access"))
