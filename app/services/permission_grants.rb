# Compatibility alias (PermissionRole pilot, Step 4): the implementation now
# lives in OrganizationAccess::PermissionGrants. Application callers use the
# namespaced constant; this alias keeps the legacy name resolving to the very
# same module until legacy access is removed (migration plan, step 6).
PermissionGrants = OrganizationAccess::PermissionGrants
