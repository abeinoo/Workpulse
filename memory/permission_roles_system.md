---
name: permission-roles-system
description: Dynamic permission roles system — PermissionRole model, User#can?, policy refactoring, admin UI, seeds, i18n
metadata:
  type: project
---

Added in May 2026. Coexists with the org-role enum (`super_admin/area_manager/branch_manager/accountant/employee`).

**New tables:** `permission_roles` (jsonb `permissions` column, `system_default` flag), `permission_role_id` FK on `users`.

**Key model:** `app/models/permission_role.rb` — defines `PERMISSION_GROUPS` constant (9 groups, 21 permissions), `has_permission?(perm)` method.

**Authorization:** `User#can?(permission)` — super_admin always returns true; others check permission_role. `ApplicationPolicy#can?` delegates to it. All 14 policies updated to accept `can?` as an alternative to role-based checks.

**Permission groups:** employees, attendance, payroll, adjustments, requests, shifts, reports, settings, administration.

**Routes:** `resources :permission_roles` under `/admin/` namespace. Extra member actions: `assign_user` (POST), `remove_user` (DELETE).

**Controller:** `Admin::PermissionRolesController` — skips `require_super_admin!`, adds own check for `can?(:manage_roles)`.

**Sidebar:** Updated to show admin section items based on `can?` checks; shows permission_role name in user footer when assigned.

**Seeds:** 7 default system_default roles: HR Manager, Payroll Reviewer, Attendance Supervisor, Finance Manager, Operations Manager, Read-Only Manager, Branch Supervisor.

**i18n:** Full EN + AR translations under `admin.permission_roles.*`.

**Stimulus:** `permission_role_form_controller.js` — group toggles with indeterminate state, select all / clear all.

Why: Business requested Fresha-style dynamic roles so any employee can be granted specific feature access independent of their org role.
How to apply: When adding new features, add a permission key to PERMISSION_GROUPS and check `can?(:new_permission)` in the policy.
