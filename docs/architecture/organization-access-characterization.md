# Organization & Access — Characterization Coverage

**Phase:** characterization only. No production code, schema or migration changes. Production files modified in this
phase: **0** (verified: no file under `app/`, `config/`, `db/` or `lib/` is newer than the first characterization spec).
**Code baseline:** branch `feature/api-foundation` @ `a4e9a96`, plus the uncommitted Organization & Access
security-hardening changes. Those are documented in `organization-access-migration-readiness.md`; this phase did
not touch them.

## 1. Purpose

Record what Organization & Access does **today** so that a later mechanical or domain migration can be checked
against it. These specs describe current behaviour, including known defects (marked as such). They are not a
statement of desired behaviour.

## 2. Scope

**In scope:**

* `Business`, `Branch`, `User` (account concern), `PermissionRole`, `UserAuditLog`
* authentication: web session, API session, account claim
* authorization: Pundit policies, access scopes, privilege hierarchy
* role and permission management
* business settings and locale preferences
* admin user, branch and role administration

Cross-domain behaviour is included **only** as the contracts other domains consume from Organization & Access. No
Workforce, Attendance & Payroll, Inventory, Finance or Reporting logic is characterized here.

## 3. Existing test coverage (inventory)

| Class | Spec | Examples | Notes |
|---|---|---|---|
| **A. Strong characterization** | `spec/models/user_spec.rb` | 74 | login lookup, activation, uniqueness, employee code, `can?`, `owner?`, `manages_*` |
| A | `spec/models/permission_role_spec.rb` | 146 | catalogue, dependencies, scopes, validation |
| A | `spec/services/employee_scope_spec.rb` | 26 | self/branch/area/business, precedence |
| A | `spec/services/branch_scope_spec.rb` | 15 | management and shift-assignment resolution |
| A | `spec/lib/business_day_spec.rb` | 16 | business-day rollover |
| A | `spec/requests/admin/users_spec.rb` | 36 | list, profile, create, update, delete, attachments, `toggle_active`, session block |
| A | `spec/requests/admin/branches_spec.rb` | 18 | branch type, terminal IDs, authorization |
| A | `spec/requests/preferences_spec.rb` | 12 | locale preference and priority, `lang`/`dir` |
| A | `spec/services/approvals/self_approval_spec.rb` | 6 | segregation of duties |
| A | `spec/requests/api/v1/characterization/authentication_spec.rb` | 15 | API login/logout, Devise 401, CSRF, CORS |
| A | `spec/requests/api/v1/sessions_spec.rb`, `standard_contract/rate_limiting_spec.rb` | 6 + 7 | API session, login rate limits |
| **B. Security / regression** | `spec/requests/security/organization_access_security_spec.rb` | 43 | OA-S1…S7 |
| B | `spec/requests/security/organization_access_scope_hierarchy_spec.rb` | 23 | OA-S8, privilege hierarchy |
| B | `spec/requests/security/organization_access_view_and_role_scope_spec.rb` | 17 | profile view scope, role-scope guard |
| B | `spec/services/users/registration_service_spec.rb` | 18 | invitation-based claim, enumeration |
| **C. Partial** | `spec/models/business_spec.rb` | 20 | validations and employee code; settings accessors only partly |
| C | `spec/models/branch_spec.rb` | 21 | validations and scopes; no admin flows |
| C | `spec/requests/admin/settings_spec.rb` | 4 | employee-code starting number only |
| C | `spec/policies/user_policy_spec.rb`, `permission_role_policy_spec.rb`, `branch_policy_spec.rb` | 23 + 16 + 12 | policy predicates; owner and manager basics |
| C | `spec/requests/permission_matrix_verification_spec.rb` | 95 | cross-domain permission matrix (3 baseline failures) |
| **D. Missing before this phase** | web login/logout/session, self password change, admin-reset audit contents, role CRUD (normal path), branch create/active/destroy outcomes, settings ownership, unauthenticated `/locale`, cross-domain contracts (`scope_for`, warehouse ids, depositor, sidebar, effective branch, `ApplicationPolicy` helpers, settings defaults), audit side effects | — | added below |

## 4. New characterization coverage

New directory: `spec/characterization/organization_access/`. It has **69 examples** in 5 files and passes in
default and random order.

| File | Examples | Covers |
|---|---|---|
| `web_session_spec.rb` | 13 | unauthenticated redirect; login by email (case-insensitive) and phone; admin landing for `manage_settings`; wrong password; inactive and pending accounts; logout; session persistence and invalidation on deactivation; web authorization failure response; locale and timezone request context |
| `account_management_spec.rb` | 11 | self password change (current password, audit, session kept); admin reset audit (actor, target, IP); toggle status; ownership transfer; admin-created pending account in the actor's business; deletion and the restricted-deletion defect |
| `permission_roles_spec.rb` | 14 | index/show business isolation; show membership lists (owner never offered); create (defaults, dependency errors, duplicate names, scope normalization); update propagates to holders; destroy rules; assign/remove; role changes not audited; owner effective permissions; accountant-defaults defect |
| `branches_and_settings_spec.rb` | 15 | branch index isolation; business assigned from the actor; active flag; manager assignment drives `managed_branch_ids`; destroy and the restricted-deletion defect; branch changes not audited; settings ownership; JSON settings clamping; invalid timezone; `manage_settings` required; settings not audited; `/locale` with and without a session |
| `access_contracts_spec.rb` | 16 | `User#scope_for`, `managed_branch_ids` / `area_managed_branch_ids`, `inventory_warehouse_ids` / `warehouse_scoped?`, `eligible_depositor?`, `management_sidebar?`, `effective_branch_on`; `ApplicationPolicy` scope helpers (`filter_by_branch_scope`, `filter_by_data_scope`, `branch_within_scope?`); business settings defaults and validation |

## 5. Important behavioural contracts

* **Tenancy.** Every admin screen of this domain loads records through `current_user.business`.
  * Another business's records → 404.
  * `business_id` in params is ignored for branches, users and settings.
  * `owner_id` and the business `name` cannot be changed through settings.
* **Login.** Login uses email (case-insensitive) or phone.
  * Inactive accounts and pending (passwordless) accounts cannot sign in.
  * `manage_settings` holders land on `/admin`; everyone else lands on `/`.
* **Session.** A live session ends on the next request after deactivation. Logout ends the session.
* **Request context.** Each request runs with the business timezone and a locale resolved in this order: user
  preference → session → business default → app default. The unauthenticated `/locale` endpoint stores the locale in
  the session only.
* **Password changes.** Self changes require the current password and keep the session. Admin resets require
  `manage_employees` within scope and hierarchy. Both write a `UserAuditLog` entry.
* **Account creation.** Admin-created and onboarded employees start as **pending registration** (no password), get a
  generated employee code, and have no role.
* **Roles.**
  * A role is created in the actor's business. Role-type defaults fill an empty permission list.
  * Missing dependencies and duplicate names are rejected.
  * Scopes are normalized and dropped for permissions the role does not hold.
  * Editing a role changes the effective permissions of every holder.
  * A role with users cannot be deleted.
* **Owner.** The owner holds every permission without a role. `scope_for` is always `business` for the owner.
* **Branches.**
  * Branches are created in the actor's business and are active by default.
  * Manager columns drive `managed_branch_ids` / `area_managed_branch_ids`, which feed every access scope.

## 6. Security contracts

Characterized by the security specs (class B) and **not duplicated** in the characterization suite:

| Contract | Spec |
|---|---|
| Self-service fields only on one's own record; no self role/status/access change | `organization_access_security_spec` (OA-S1) |
| Roles of another business never assignable (model validation + scoped lookup) | same (OA-S2) |
| Role changes need `manage_roles`; no granting or managing above one's own permissions | same (OA-S3) |
| Owner protected (password, status, deletion, login identifiers, role) | same (OA-S4/S5) |
| Account claim requires an invitation link; one generic error | same (OA-S6) + `registration_service_spec` |
| Branch/area managers from the same business only | same (OA-S7) |
| Employee management limited to the actor's scope | `organization_access_scope_hierarchy_spec` (OA-S8) |
| Privilege hierarchy (administrative permissions must be covered) | same |
| Profile view limited to the actor's scope | `organization_access_view_and_role_scope_spec` |
| No granting a permission at a broader scope than one's own | same |

## 7. API contracts

Organization & Access exposes only the session endpoints. Both are characterized in
`spec/requests/api/v1/characterization/authentication_spec.rb` and
`spec/requests/api/v1/standard_contract/rate_limiting_spec.rb`.

| Endpoint | Contract |
|---|---|
| `POST /api/v1/auth/login` | Accepts a top-level JSON body or a `session` key. Login is email or phone. Sets the Devise session cookie; no token. 200 `{success, data: user_payload}`. 401 legacy error for wrong, unknown or inactive credentials (one message). 400 when credentials are missing. 429 standard error when rate-limited |
| `DELETE /api/v1/auth/logout` | 200 legacy success; Devise 401 when not signed in |
| `/api/v1/businesses`, `/branches`, `/users` | Declared but unimplemented (routing error); listed as defect D2 in `docs/api/baseline.md` |

No API endpoint mutates Organization & Access data, so there is no further API surface to characterize.

## 8. Cross-domain contracts

Characterized in `access_contracts_spec.rb` (plus the existing specs noted there):

| Consumer | Contract |
|---|---|
| All domains (policies) | `User#can?`, `#scope_for`, `#owner?`; `ApplicationPolicy` helpers `filter_by_data_scope`, `filter_by_branch_scope`, `branch_within_scope?`; `EmployeeScope`, `BranchScope` |
| Workforce, Attendance & Payroll | `managed_branch_ids`, `area_managed_branch_ids`, `effective_branch_on`; branch membership via `BranchMembership` (Workforce-owned, consumed by `EmployeeScope`) |
| Inventory & Purchasing | `inventory_warehouse_ids`, `warehouse_scoped?` |
| Finance & Sales | `eligible_depositor?`; finance settings on `Business` |
| Attendance | attendance-duration settings on `Business` |
| Navigation / UI shell | `management_sidebar?` |
| Workforce, Finance & Sales, Inventory & Purchasing | `Approvals::SelfApproval` (existing spec) |

## 9. Known baseline failures

None of the failures below are caused by this phase. All exist with every Organization & Access change stashed.
Failures relevant to this domain:

* `spec/models/permission_role_translations_spec.rb` (2) and
  `spec/requests/admin/permission_roles_localization_spec.rb` (4): the translation
  `admin.permission_roles.permissions.manage_bank_disputes` is missing in en and ar.
* `spec/requests/permission_matrix_verification_spec.rb` (3): payroll-dashboard exposure checks (an Attendance &
  Payroll concern surfaced by the permission matrix).

The repository-wide baseline (other domains) is listed in `docs/api/baseline.md` and the readiness document.

## 10. Known existing defects (characterized, not fixed)

| ID | Defect | Spec |
|---|---|---|
| OA-D1 | `Admin::UsersController#destroy` ignores the destroy result: a user with restricted history (e.g. a custody account) is **not** deleted, but the success notice "employee removed" is shown | `account_management_spec.rb` |
| OA-D2 | `Admin::BranchesController#destroy` ignores the destroy result: a branch with restricted history (e.g. a POS terminal) is **not** deleted, but "branch removed" is shown | `branches_and_settings_spec.rb` |
| OA-D3 | The built-in `accountant` role-type defaults include `view_sales_transactions_verification` without its dependency `view_daily_reconciliation`, so creating an accountant role from its defaults always fails validation. The other role types are valid | `permission_roles_spec.rb` |
| OA-D4 | **Audit gap:** role assignment and removal, permission-role changes, account status changes, branch changes and settings changes create **no** audit record. Only password changes and resets are audited (`UserAuditLog`). This conflicts with the audit-first principle | `account_management_spec.rb`, `permission_roles_spec.rb`, `branches_and_settings_spec.rb` |
| — | Missing translation `manage_bank_disputes` (see §9) | baseline specs |

## 11. Remaining coverage gaps

| Gap | Risk | Note |
|---|---|---|
| `Admin::BaseController` gate per permission (which of the 13 permissions open which admin screens) | Medium | Only partly covered by `permission_matrix_verification_spec` (3 baseline failures in that file) |
| `WorkspaceHelper` / sidebar rendering per role | Low | UI-shell infrastructure; `sidebar_active_state_spec` has 2 baseline failures |
| User deletion cascades into other domains (`dependent: :destroy` on assignments, attendance, payroll entries, advances…) | Medium | Association declarations are matched in `user_spec`; cross-domain data effects are deliberately not characterized here |
| Onboarding approval → account creation | Low | Owned by Workforce (`employee_data_requests` specs); OA side covered by the pending-account and invitation specs |
| Remember-me cookie behaviour | Low | Devise default; not characterized |
| Email password reset | — | Not available (Devise password routes skipped) |
| Request-context timezone | Low | Characterized through one controller stub (`web_session_spec`); no direct observable endpoint exists |

## 12. Migration readiness assessment

| Area | Assessment |
|---|---|
| `PermissionRole` (model, policy, admin screens), `UserAuditLog`, `Approvals::SelfApproval`, `BranchPolicy`, settings, preferences, locale, web/API session controllers, `BusinessDay` | **SAFE TO START MIGRATION**: behaviour, security and side effects are characterized |
| `Branch` model and branch administration (CRUD) | **SAFE TO START**, with OA-D2 documented. `admin/branches#show` (cross-domain dashboard) remains legacy |
| Access scopes (`EmployeeScope`, `BranchScope`, `ApplicationPolicy` helpers) | **PARTIALLY COVERED**: contracts are characterized, but they depend on Workforce membership (`BranchMembership`). Move them only together with the membership contract |
| `User` model and `admin/users` | **PARTIALLY COVERED**: account behaviour and security are characterized. The User ≠ Employee split, the cascading deletes and the mixed admin form make a structural move risky until Workforce is characterized |
| Admin-area gate and navigation | **NOT SAFE YET** to restructure: per-permission coverage is incomplete and the permission-matrix spec has baseline failures |

**Overall:** Organization & Access is **SAFE TO START MIGRATION for the low-coupling components** (steps 4–5 of the
readiness sequence: introduce the structure, move `PermissionRole`, `UserAuditLog`, `SelfApproval`, `BranchPolicy`,
settings/locale/preferences, `BusinessDay`). It is **PARTIALLY COVERED** for `User`, `admin/users` and the access
scopes. These should move only after the Workforce boundary (Employee stewardship, membership contract) is
characterized.

**Test results:** see the "Characterization Status" section of `organization-access-migration-readiness.md`.
