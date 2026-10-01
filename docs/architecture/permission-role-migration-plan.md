# PermissionRole — Migration Pilot Plan (Organization & Access)

**Status:** design only. Nothing in this document has been implemented.
**Branch:** `feature/api-foundation` @ `7c69c9e`.
**Related:** `module-boundaries.md`, `organization-access-migration-readiness.md`,
`organization-access-characterization.md`.

**Constraints:**

* one Rails application and one database (a modular monolith)
* no HTTP calls between domains
* gradual, strangler-style migration
* no schema change

---

## 1. Executive summary

`PermissionRole` is the first Organization & Access component to move behind a domain boundary. It is a small table
(10 columns). Its behaviour lives almost entirely inside one model (455 lines, mostly declarative permission
constants), one controller, one policy and one service (`PermissionGrants`).

The coupling is wide but shallow: about 550 permission checks across every domain go through **one method**,
`User#can?`, plus `User#scope_for`. Almost nothing outside Organization & Access touches the model directly.

**Conclusions:**

1. **No database migration is required.** The table, columns, indexes and foreign keys stay as they are (§8.1).
2. **The `PermissionRole` constant must not be renamed or namespaced in this pilot.** 16 historical data migrations,
   the factory (`:permission_role`), about 150 spec files and the `PermissionRole::PERMISSION_GROUPS` /
   `SCOPE_OPTIONS` references in other domains all depend on it. The pilot introduces a **boundary**, not a rename.
3. **`User#can?` and `User#scope_for` remain the stable cross-domain authorization interface.** They are rewired to
   delegate to the Organization & Access boundary, so none of the about 550 call sites change.
4. The pilot moves **behaviour**, not files:
   * Role administration (create, update, destroy, assign, remove) moves from two controllers into Organization &
     Access services returning the standard `Result`.
   * The permission catalogue (groups, scopes, dependencies) gets a read-only interface that other domains use
     instead of `PermissionRole::…` constants.
5. **Readiness:** safe to start **after** the 6 REQUIRED tests in **Step 1 — Characterization Gaps** are added and
   green against unchanged code. Everything else is already characterized.
6. **Locked decisions (§1.1):**
   * no new audit records (D1)
   * OA-D3 not fixed (D2)
   * R-L4 out of scope (D3)
   * `PermissionRole` / `permission_roles` unchanged (D4)

### 1.1 Locked decisions

These decisions are final for the pilot. They are not open questions.

| ID | Decision | Consequence for the pilot |
|---|---|---|
| D1 (was Q1) | **No new audit records.** Role creation, editing, deletion and assignment stay unaudited, exactly as today (OA-D4) | The new services must **not** include `AuditLoggable` calls for role changes. Role-change auditing is a separate future audit/security task. The characterization examples asserting "not audited" must stay green |
| D2 (was Q2) | **OA-D3 is not fixed in the pilot.** The invalid `accountant` role-type defaults remain an existing defect, tracked as a separate bug-fix task | `DEFAULT_PERMISSIONS_BY_ROLE_TYPE` is moved and wrapped byte-identical. The characterization example "cannot create an accountant role from its defaults (known defect)" must stay green until that separate fix |
| D3 | **R-L4 (`lib/tasks/attendance.rake`) stays out of scope.** It is an unrelated existing defect and is not fixed | The rake task is not touched by any pilot step |
| D4 | **Database contract is fixed.** The model stays `PermissionRole` and the table stays `permission_roles`. No rename, no migration | The pilot only adds a boundary around the existing implementation |

## 2. Current architecture

| Concern | Where it lives today |
|---|---|
| Role data (`name`, `description`, `role_type`, `workspace`, `permissions` jsonb, `permission_scopes` jsonb, `business_id`) | `permission_roles` table; `app/models/permission_role.rb` |
| Permission catalogue: `PERMISSION_GROUPS`, `ALL_PERMISSIONS`, `PERMISSION_DEPENDENCIES` / `DEPENDENTS`, `DEFAULT_PERMISSIONS_BY_ROLE_TYPE`, `ROLE_TYPES` | constants in the model |
| Scope catalogue: `SCOPE_OPTIONS`, `LEGACY_SCOPE_ALIASES`, `SCOPABLE_PERMISSIONS`, `BRANCH_MINIMUM_SCOPE_PERMISSIONS`, `.scope_options_for`, `.normalize_scope` | constants and class methods in the model |
| Role normalization (defaults from `role_type`, de-duplication, scope pruning and normalization) | `before_validation` in the model |
| Role validation (name unique per business, valid permissions, valid scopes, dependencies) | model validations |
| Effective permission evaluation | `User#can?` (owner → everything; no role → nothing; otherwise `role.has_permission?`), `User#scope_for` (owner → `"business"`), `User#management_sidebar?` (role `workspace`) |
| Grant / escalation rules | `PermissionGrants` (`app/services/permission_grants.rb`, a plain module): grantable permissions, privilege hierarchy (`covers?`), scope rank, `manageable_role?`, `can_change_role?` |
| Role administration web UI | `Admin::PermissionRolesController`, 5 views, `permission_role_form_controller.js` (Stimulus) |
| Role assignment | in **two** places: `Admin::PermissionRolesController#assign_user` / `#remove_user`, and `Admin::UsersController#assign_role` (private helper used by `create` / `update`) |
| Authorization of role administration | `PermissionRolePolicy` (`manage_roles`; update/destroy only for manageable roles; `Scope` = own business); `UserPolicy::ROLE_ATTRIBUTES`; `Admin::BaseController#require_admin_access!` |
| API exposure | `Api::V1::SessionsController#user_payload` → `permissions: user.permission_role&.permissions \|\| []` (documented in `docs/api/openapi.yaml`) |
| Seeds and tasks | `db/seeds.rb` (default roles); `lib/tasks/attendance.rake` (role lookup — see §11 R-L4); `lib/tasks/laundry.rake` (message text only) |

There are **no** jobs, callbacks into other domains, serializers, presenters or helpers for `PermissionRole`.

## 3. Ownership

**Organization & Access owns `PermissionRole`**, consistent with `module-boundaries.md`, where Organization & Access
is responsible for role, permissions and access scopes.

| | |
|---|---|
| **Owns** | the role record and its lifecycle (create, update, delete); the permission catalogue (names, groups, dependencies, role-type defaults); the scope vocabulary (`self`/`branch`/`area`/`business` plus legacy aliases); role-to-user assignment (`users.permission_role_id`, which Organization & Access stewards on the shared `users` table); the grant and escalation rules (`PermissionGrants`); effective-permission evaluation |
| **May read** | `Business` (tenant and owner), `User` account fields (`owner?`, `business_id`, `active`), user role membership for counts and lists |
| **May be called by** | every domain, **read-only**: "may this user do X?", "at what scope?", "which permissions form group G?", "what is this user's role name?". Organization & Access admin controllers and API for writes |
| **Must not be modified directly by** | any other domain (writes to `permission_roles` or `users.permission_role_id`), any controller outside Organization & Access, seeds or rake tasks outside an Organization & Access entry point. Data migrations stay as they are, as frozen history |

## 4. Dependency map

### 4.1 PermissionRole → others

| Target | Kind | Detail |
|---|---|---|
| Business | association | `belongs_to :business`; `Business has_many :permission_roles, dependent: :destroy`; foreign key `permission_roles.business_id` |
| User | association | `has_many :users, dependent: :nullify`; foreign key `users.permission_role_id` `on_delete: :nullify`; `User belongs_to :permission_role, optional` plus the `permission_role_in_same_business` validation |
| Branch, Employee/Workforce, Attendance & Payroll, Inventory & Purchasing, Finance & Sales, Reporting | none | the model has no references outward. The permission **names** describe those domains, but that is data, not code |

### 4.2 Others → PermissionRole (inventory and classification)

**Internal to Organization & Access:**

| File | Reference | Kind |
|---|---|---|
| `app/models/permission_role.rb` | the model | — |
| `app/models/user.rb` | `belongs_to`, same-business validation, `can?`, `scope_for`, `management_sidebar?` | association, authorization lookup |
| `app/models/business.rb` | `has_many :permission_roles` | association |
| `app/services/permission_grants.rb` | `ALL_PERMISSIONS`, `SCOPABLE_PERMISSIONS`, `.normalize_scope`, `user.permission_role.permissions` | read, authorization lookup |
| `app/policies/permission_role_policy.rb` | policy and scope | authorization |
| `app/policies/user_policy.rb` | `ROLE_ATTRIBUTES` | authorization |
| `app/controllers/admin/permission_roles_controller.rb` | full CRUD, assign/remove, grant checks | controller coupling, write |
| `app/controllers/admin/users_controller.rb` | `includes`, `assign_role` | controller coupling, write |
| `app/controllers/admin/base_controller.rb` | `can?(:manage_roles)` and others | authorization |
| `app/controllers/api/v1/sessions_controller.rb` | `user.permission_role&.permissions` | read (API contract) |
| `app/views/admin/permission_roles/*` (5), `app/javascript/controllers/permission_role_form_controller.js` | catalogue constants, role attributes | read (UI) |
| `app/views/admin/users/_form.html.erb`, `admin/users/show.html.erb`, `admin/dashboard/index.html.erb`, `admin/dashboard_controller.rb` | role select, `role.name`, `includes` | read (UI) |
| `app/views/layouts/_sidebar.html.erb` | nav link, `current_user.permission_role&.name` | read (UI shell) |
| `app/policies/application_policy.rb`, `app/services/employee_scope.rb`, `app/services/branch_scope.rb` | `SCOPE_OPTIONS` vocabulary (comments) and `user.scope_for` | authorization lookup (Organization & Access access infrastructure, see §8) |
| `config/routes.rb` | `resources :permission_roles` (+ `assign_user`, `remove_user`) | routing |
| `db/seeds.rb` | `PermissionRole.find_or_create_by!` | write (setup) |

**Cross-domain dependencies:**

| File | Domain | Reference | Kind |
|---|---|---|---|
| `app/controllers/laundry/base_controller.rb` | Inventory & Purchasing (Laundry) | `PermissionRole::PERMISSION_GROUPS[:laundry_operations]` and `[:laundry_cost_reports]` | read (catalogue) |
| `app/policies/laundry_batch_policy.rb` | Inventory & Purchasing (Laundry) | comments only | — |
| `app/policies/employee_data_request_policy.rb` | Workforce | `PermissionRole::PERMISSION_GROUPS[:employee_onboarding]` | read (catalogue) |
| `app/controllers/till_handovers_controller.rb` (2), `finance/daily_reconciliations_controller.rb`, `services/finance/depositor_assigner.rb`, `services/finance/deposit_responsibility_transfer_requester.rb` | Finance & Sales | `.includes(:permission_role)` on users, to preload for `eligible_depositor?` / `can?` | association preload (performance) |
| `app/views/admin/branches/_employees.html.erb`, `admin/branches_controller.rb` | Organization & Access screen showing Workforce data | `employee.permission_role&.name`, `includes` | read (display) |
| `lib/tasks/attendance.rake` | Attendance & Payroll | `User.joins(:permission_role).where(permission_roles: { role: "super_admin" })` | read — **broken**, see R-L4 |
| `lib/tasks/laundry.rake` | Inventory & Purchasing | message text only | — |
| **Every policy, controller, helper and view** (policies about 350, controllers 75, views 99, helpers 19, services 11, models 4 call sites) | all domains | `user.can?(:perm)` / `can?(:perm)` | authorization lookup **through User** — does not touch `PermissionRole` |
| About 20 call sites (API v1 payroll and reports, attendance, dashboard, finance, laundry, performance, shift assignments, till handovers, and about 22 policies via `ApplicationPolicy`) | all domains | `user.scope_for(:perm)` | authorization lookup **through User** |
| `db/migrate/*` (16 files call `PermissionRole.` directly; 5 define an inline model) | — | historical data backfills | write (frozen history) |

## 5. Public interface (derived from actual usage)

Every row below is backed by existing call sites. Nothing is speculative.

| # | Need observed in the code | Proposed interface | Replaces |
|---|---|---|---|
| I1 | "May this user do X?" (about 550 sites) | **`User#can?(permission)`**, unchanged signature; internally delegates to `OrganizationAccess::Authorization.can?(user, permission)` | the `permission_role.has_permission?` body |
| I2 | "At what scope?" (about 20 sites) | **`User#scope_for(permission)`**, unchanged; delegates to `OrganizationAccess::Authorization.scope_for(user, permission)` | the `permission_role&.scope_for` body |
| I3 | Permission groups as a set (Laundry, Workforce onboarding) | `OrganizationAccess::PermissionCatalog.group(:laundry_operations)` → frozen array of strings | `PermissionRole::PERMISSION_GROUPS[...]` outside Organization & Access |
| I4 | Scope vocabulary (`ApplicationPolicy`, `BranchScope`, `PermissionGrants`) | `PermissionCatalog.scope_options`, `.normalize_scope(value)` | `PermissionRole::SCOPE_OPTIONS` / `.normalize_scope` |
| I5 | Explicit permission list for the API session payload | `OrganizationAccess::Authorization.granted_permissions(user)`. **Must keep today's contract:** role permissions, or `[]` with no role, and **`[]` for the owner**, because the owner has no role | `user.permission_role&.permissions \|\| []` |
| I6 | Role name for display (sidebar, user show, dashboard, branch employees) | `User#role_name` (nil when no role); the owner and "staff" labels stay in views | `user.permission_role&.name` in views |
| I7 | Workspace routing | `User#management_sidebar?`, unchanged | — |
| I8 | Role assignment (two controllers today) | `OrganizationAccess::RoleAssignment.call(actor:, user_id:, role_id:)` → `Result` | `assign_user` / `remove_user` bodies and `Admin::UsersController#assign_role` |
| I9 | Role lifecycle | `OrganizationAccess::RoleCreator`, `RoleUpdater`, `RoleDestroyer` → `Result` (each loads the role by **id** inside `actor.business`, per CLAUDE.md "Services accept IDs") | controller `create` / `update` / `destroy` bodies and `grants_ungrantable_permissions?` |
| I10 | Grant rules | `OrganizationAccess::PermissionGrants`, with the same methods as today. The top-level `PermissionGrants` stays as an alias until step 6 | — |
| I11 | Preloading for permission checks | Keep `includes(:permission_role)` as an **allowed** infrastructure coupling, documented. Optionally a `User.with_access_preloaded` scope later | — |

**Not exposed:**

* the `PermissionRole` record itself to other domains
* `permissions` / `permission_scopes` jsonb shapes
* `PERMISSION_DEPENDENCIES` (Organization & Access UI only)
* role-type defaults
* `workspace` enum values

Other domains never write roles.

## 6. Test coverage (safety net)

| Behaviour | Specs | Status |
|---|---|---|
| Catalogue integrity, dependencies, scope validation, normalization, legacy aliases, role-type defaults | `spec/models/permission_role_spec.rb` (146) | **SAFE** |
| Catalogue translations | `spec/models/permission_role_translations_spec.rb` (8), `spec/requests/admin/permission_roles_localization_spec.rb` (11) | **PARTIAL**: 6 baseline failures (missing `manage_bank_disputes` key) |
| `User#can?`, `#owner?`, `#scope_for`, `#management_sidebar?` | `spec/models/user_spec.rb` (74), `characterization/organization_access/access_contracts_spec.rb` | **SAFE** |
| `PermissionRolePolicy` | `spec/policies/permission_role_policy_spec.rb` (16) | **SAFE** |
| Role admin web flows (index/show isolation, create, defaults, dependency and duplicate errors, scope normalization, update propagation, destroy rules, assign/remove, not audited, owner permissions) | `characterization/organization_access/permission_roles_spec.rb` (14) | **SAFE** |
| Escalation (`cannot_grant`), scope escalation (`scope_too_broad`), `manageable_role?`, `can_change_role?` (never self or owner, cross-business role), assignment via the users form | `spec/requests/security/organization_access_security_spec.rb`, `organization_access_scope_hierarchy_spec.rb`, `organization_access_view_and_role_scope_spec.rb` (83 total) | **SAFE** |
| Scope resolution consuming `scope_for` | `employee_scope_spec` (26), `branch_scope_spec` (15), `access_contracts_spec` (ApplicationPolicy helpers) | **SAFE** |
| Cross-domain permission behaviour | `spec/requests/permission_matrix_verification_spec.rb` (95) plus about 100 domain request specs that build roles via `create(:permission_role, ...)` / `api_user_with` | **PARTIAL**: 3 baseline failures (payroll analytics) |
| API session `permissions` field | `api/v1/characterization/authentication_spec.rb` (keys; `[]` without a role) | **PARTIAL**: no example for a user **with** a role, nor for the owner (`[]`) |
| `PermissionGrants` as a unit | — | **MISSING**: only covered indirectly through request specs |
| Laundry and onboarding gates via `PERMISSION_GROUPS` | `spec/requests/laundry/*`, `employee_data_requests` specs | **PARTIAL**: behaviour covered; no spec pins the group membership consumed |
| Admin-area gate (`require_admin_access!`, 13 permissions) | partly via the permission matrix | **PARTIAL** |
| Role-form Stimulus controller (defaults, dependency auto-check) | — | **MISSING** (JavaScript; out of the Ruby suite) |
| `lib/tasks/attendance.rake` role lookup | — | **MISSING** (and broken, R-L4) |

The exact list of tests to add before the boundary is introduced, with what is already covered, is in
**Step 1 — Characterization Gaps** below.

## Step 1 — Characterization Gaps

**Question answered:** what tests are still missing before the `PermissionRole` boundary is introduced?

**Selection rule:** a test is **REQUIRED** only if the pilot changes or relocates the code path it pins, and no
existing spec would fail if that path silently changed. Everything else is **ALREADY COVERED** (with the spec that
covers it) or **OPTIONAL** (lower risk, or not touched by the pilot). No test is written in this phase.

**Prerequisite (not a test): baseline snapshot.** Before Step 1 tests are added, record the full-suite **failing
example IDs** (87 today) in a file. Success criterion 4 compares IDs, not counts. A count would hide a new failure
inside `permission_matrix_verification_spec` (3 baseline failures) or the translation specs (6).

| # | Focus | Test to add | Class | Why / evidence |
|---|---|---|---|---|
| G1 | `PermissionGrants` direct behaviour | **Unit spec of the decision table**, one example per row: `scope_rank` (`nil`/blank → `area` rank; legacy `business_wide` → `business` rank; each canonical value); `grantable_permissions` (owner → `ALL_PERMISSIONS`, no role → `[]`); `ungrantable`; `covers?` (owner covers anyone; nobody but the owner covers the owner; missing administrative permission → not covered); `overbroad_scopes` (blank role scope vs branch actor); `manageable_role?`; `can_change_role?` with `from: nil` and `to: nil`, self, owner target | **REQUIRED** | Step 3 relocates the module and step 4 calls it from new services. Today it is only reached through request specs, and several branches (nil scope rank, legacy alias rank, `from`/`to` nil) are exercised only incidentally. A unit table pins the exact decisions so the move cannot alter them unnoticed |
| G2 | API login, normal role | `POST /api/v1/auth/login` for a user **with** a role → `data.permissions` equals the role's permission list (order as stored) | **REQUIRED** | Step 2 rewires `permissions:` through `Authorization.granted_permissions`. Today only the no-role `[]` case is asserted (`authentication_spec.rb:23`) |
| G3 | API login, owner | Same request as the owner → `data.permissions == []` and `role == "owner"` | **REQUIRED** | The owner has every permission but **no role**, so the payload is `[]`. A "helpful" delegation to effective permissions would change the mobile contract (open question Q3). Nothing pins it today |
| G4 | Laundry permission groups | Pin exact membership: `PERMISSION_GROUPS[:laundry_operations]` and `[:laundry_cost_reports]` equal today's literal lists (model-level, 2 examples) | **REQUIRED** | `Laundry::BaseController::LAUNDRY_PERMISSIONS` is built from these groups, and step 2 switches it to `PermissionCatalog.group`. `permission_role_spec` does not assert group contents, so a dropped member would silently lock users out of the workspace |
| G4a | Laundry gate behaviour | Gate entry for a towel viewer and a cost-report-only user; denial for no laundry permission | **ALREADY COVERED** | `finance_laundry_workspace_navigation_spec.rb:146,153,160`; `laundry/cost_reports_authorization_spec.rb:30,41` |
| G4b | Laundry gate, every group member | One request per member (8 permissions) | **OPTIONAL** | G4 plus the gate examples already cover the group → gate wiring; per-member requests add runtime for little extra protection |
| G5 | Employee-onboarding permission group | Pin exact membership of `PERMISSION_GROUPS[:employee_onboarding]` (1 example) **and** `EmployeeDataRequestPolicy#index?` is **true** for a holder of exactly one group member (e.g. `review_employee_requests` only) | **REQUIRED** | Step 2 switches the policy to `PermissionCatalog.group`. The policy spec only asserts `index?` **false** (`employee_data_request_policy_spec.rb:28`). The positive path, which also passes **string** permissions to `can?`, is unpinned |
| G6 | Role create/update/delete/assign | — | **ALREADY COVERED** | `characterization/organization_access/permission_roles_spec.rb` (14: create, defaults, dependency/duplicate 422, scope normalization, update propagation, destroy with and without users, assign/remove, not audited); security specs (assign via role screen and user form, `manage_roles` required, cannot edit/delete/assign above own, owner role protected) |
| G6a | Role update failure path | `PATCH` with a dependency violation → 422, role unchanged | **OPTIONAL** | Step 4 ports `update`. The create-422 path and the update-escalation refusal are already pinned, and the update re-render uses the same validations |
| G7 | Effective permission behaviour | `User#can?` returns the same result for a **String** and a **Symbol** permission (role holder and owner), and `false` for an unknown permission name | **REQUIRED** | Step 2 replaces the `can?` body (R-H1). `user_spec.rb:339-353` covers owner / no role / delegation with symbols only, but production passes strings: `EmployeeDataRequestPolicy#index?` iterates the string group members into `can?` |
| G7a | `scope_for`, `management_sidebar?`, owner, no role, legacy alias | — | **ALREADY COVERED** | `access_contracts_spec.rb` (owner `business`, configured, legacy `business_wide` → `business`, nil), `user_spec.rb` |
| G7b | `scope_for` with a String argument | — | **OPTIONAL** | Same `to_s` path as G7; G7 already guards the delegation pattern |
| G8 | Business scope | — | **ALREADY COVERED** | Role index isolation (characterization); foreign role show/edit/delete/assign → 404 and foreign role via the employee form (`organization_access_scope_hierarchy_spec`, `organization_access_security_spec.rb:75,82,102,117`); model-level same-business validation |
| G9 | Branch scope | — | **ALREADY COVERED** | `employee_scope_spec` (26), `branch_scope_spec` (15), `access_contracts_spec` (`filter_by_branch_scope`, `filter_by_data_scope`, `branch_within_scope?`); the pilot does not move scope infrastructure (Q6) |
| G10 | Role permission-scope escalation | — | **ALREADY COVERED** | `organization_access_view_and_role_scope_spec.rb` (create, widen, blank scope, edit/delete, assign via both screens, business-scoped admin allowed, owner) |
| G11 | Existing security guarantees | — | **ALREADY COVERED** | 83 examples in `spec/requests/security/organization_access_*` (OA-S1–S8, privilege hierarchy, profile view scope, role scope) plus `registration_service_spec` |
| G12 | `PermissionRolePolicy` | — | **ALREADY COVERED** | `permission_role_policy_spec.rb` (16) plus manageable checks in the security specs |
| G13 | Admin-area gate (`require_admin_access!`) per permission | 13 request examples | **OPTIONAL** | The pilot keeps `Admin::BaseController` unchanged (§8). Required only if a later step touches it |
| G14 | Role-form Stimulus controller | JavaScript test | **OPTIONAL** | Views and JavaScript are kept; only constant references may switch to `PermissionCatalog`, which G4/G5 plus a catalogue-equals-constants check guard |

**Summary:** 6 REQUIRED (G1, G2, G3, G4, G5, G7; about 20 examples), 8 ALREADY COVERED (G4a, G6, G7a, G8, G9, G10,
G11, G12), and 5 OPTIONAL (G4b, G6a, G7b, G13, G14). Once the 6 REQUIRED items are in place and green
against the **unchanged** code, step 1 of the migration sequence may start.

### Step 1 status — COMPLETE (tests only; awaiting review)

* **Baseline** (before any Step 1 spec): commit `7c69c9e`, 7042 examples, 87 failures, 1 pending. The failing IDs
  are in `docs/architecture/permission-role-baseline-failures.txt`.
* **Added:** 49 examples in 4 files under `spec/characterization/organization_access/`:

  | File | Gaps | Examples |
  |---|---|---|
  | `permission_grants_spec.rb` | G1 | 35 |
  | `permission_groups_spec.rb` | G4, G5 | 7 |
  | `effective_permissions_spec.rb` | G7 | 5 |
  | `api_session_permissions_spec.rb` | G2, G3 | 2 |

* **Result:** all 49 pass, also in random order.
  * The Organization & Access characterization suite is now 118 examples, 0 failures.
  * Related existing specs: 827 examples, 9 failures, **all 9 in the baseline**, so 0 new failures.
* **Also characterized (existing behaviour, not changed):** the owner is granted even an unknown permission name
  (`User#can?` owner short-circuit). The boundary must preserve this.
* No production code, schema or migration changes. OA-D3, R-L4 and audit behaviour are untouched (D1–D3).

## Step 2 — Boundary Status

**Status:** COMPLETE (uncommitted; awaiting review). This corresponds to step 1 of the migration sequence (§10):
introduce the boundary, delegating to today's code.

Each candidate was kept only if it has a concrete current caller to migrate in Step 3 and delegates to an existing
source of truth:

| Object | Created? | Delegates to | Why it exists / why not |
|---|---|---|---|
| `OrganizationAccess::PermissionCatalog.group(name)` (`app/services/organization_access/permission_catalog.rb`) | **Yes** | `PermissionRole::PERMISSION_GROUPS` (returns the same array object, no copy). Unknown group → `KeyError` | Step 3 callers: `Laundry::BaseController::LAUNDRY_PERMISSIONS` and `EmployeeDataRequestPolicy#index?`, the only code outside Organization & Access reading the catalogue (I3) |
| `OrganizationAccess::Authorization.granted_permissions(user)` (`app/services/organization_access/authorization.rb`) | **Yes** | `user.permission_role&.permissions \|\| []`, the exact expression the API uses today | Step 3 caller: `Api::V1::SessionsController#user_payload` `permissions:` (I5). The owner returns `[]` (G3 contract) |
| `Authorization.can?` / `.scope_for` | **No** | — | `User#can?` / `#scope_for` already **are** the cross-domain interface (I1/I2, about 570 callers that will not be migrated). A delegating twin would add a second entry point with no caller. Moving their bodies into Organization & Access is a later decision |
| `PermissionCatalog` scope vocabulary / `ALL_PERMISSIONS` / `normalize_scope` | **No** | — | Only read in code by `PermissionGrants` (internal to Organization & Access; `ApplicationPolicy` and `BranchScope` mention `SCOPE_OPTIONS` in comments only). It belongs with the `PermissionGrants` move |
| `OrganizationAccess::PermissionGrants` | **No** | — | The plan moves it in a later step (with a top-level alias); all its callers are internal to Organization & Access. A wrapper now would have no caller to migrate in Step 3 |
| Role services (create/update/destroy/assign) | **No** | — | A later step (controller extraction), not Step 3 |
| `User#role_name` (I6) | **No** | — | It would modify the `User` model, which is out of scope for this step |

**Existing callers have NOT been migrated.** Nothing in `app/`, `lib/` or `config/` references `OrganizationAccess`
outside `app/services/organization_access/`. No existing file was modified: the diff is two new production files and
two new spec files. Existing paths (`PermissionRole::PERMISSION_GROUPS`, `user.permission_role&.permissions`,
`User#can?`, `PermissionGrants`) are unchanged.

**Tests:**

* New boundary specs `spec/services/organization_access/{permission_catalog,authorization}_spec.rb`: 8 examples,
  0 failures.
* Step 1 characterization: 49/49 green.
* Organization & Access characterization suite plus related role, user and policy specs, security, API, permission
  matrix, Laundry, onboarding and scope specs: 953 examples, 9 failures, 1 pending. The failing IDs are **identical**
  to the pre-Step-2 run and all are in `permission-role-baseline-failures.txt`.
* `bin/rails zeitwerk:check` passes (eager load); RuboCop clean; `git diff --check` clean.

**Database:** no migration, no schema change. `PermissionRole` / `permission_roles` are unchanged; no model was
modified. OA-D3, R-L4 and audit behaviour are untouched (D1–D3).

## Step 3 — Read Routing Status

**Status:** COMPLETE (uncommitted; awaiting review). This corresponds to step 2 of the migration sequence (§10):
route reads through the boundary. The change is 3 files, 4 lines; every one is a read that now goes through the
boundary with an identical result.

### Callers migrated

| Caller | Old path | New path | Why it is cross-domain | Tests covering it |
|---|---|---|---|---|
| `Laundry::BaseController::LAUNDRY_PERMISSIONS` (workspace gate) | `PermissionRole::PERMISSION_GROUPS[:laundry_operations] + [:laundry_cost_reports]` | `OrganizationAccess::PermissionCatalog.group(:laundry_operations) + .group(:laundry_cost_reports)` → same arrays | Inventory & Purchasing (Laundry) reading the Organization & Access permission catalogue | G4 `permission_groups_spec` (pins the resulting constant), `spec/requests/laundry/*`, `finance_laundry_workspace_navigation_spec`, `permission_catalog_spec` |
| `EmployeeDataRequestPolicy#index?` | `PermissionRole::PERMISSION_GROUPS[:employee_onboarding].any? { can? }` | `OrganizationAccess::PermissionCatalog.group(:employee_onboarding).any? { can? }` | Workforce (onboarding) reading the Organization & Access catalogue | G5 (every member grants `index?`, none denies), G7 (String permissions), `employee_data_request_policy_spec`, `employee_data_requests_spec`, `spec/services/employee_data_requests` |
| `Api::V1::SessionsController#user_payload` `permissions:` | `user.permission_role&.permissions \|\| []` | `OrganizationAccess::Authorization.granted_permissions(user)` (same expression) | API layer (consumed by mobile clients) reading role internals | G2 (role holder: exact list and order), G3 (owner `[]`), `api/v1/characterization/authentication_spec` (no role `[]`, payload keys, invalid credentials, unauthenticated), `sessions_spec`, `authorization_spec` |

### Callers intentionally left unchanged

| Caller | Why |
|---|---|
| Finance preloads `includes(:permission_role)`: `TillHandoversController` (2), `Finance::DailyReconciliationsController`, `Finance::DepositorAssigner`, `Finance::DepositResponsibilityTransferRequester` | They feed `eligible_depositor?` → `User#can?`, which still reads `permission_role`. The boundary does not change that path, so the preloads still prevent an N+1 and are kept (I11) |
| `User#can?`, `#scope_for`, `#management_sidebar?`, `User` / `Business` associations and the same-business validation | Internal to Organization & Access; out of scope for this step |
| `PermissionRolePolicy`, `PermissionGrants`, `UserPolicy`, `Admin::PermissionRolesController`, `Admin::UsersController`, role views and Stimulus form | Internal to Organization & Access (role administration and grant rules); a later step |
| Role-name display: `admin/dashboard`, `admin/branches/_employees` (+ `includes` in both controllers), `layouts/_sidebar` | Organization & Access admin screens and the UI shell. No boundary object exists (`User#role_name` was not created because it modifies the model) |
| `lib/tasks/attendance.rake` | R-L4, out of scope (D3) |
| Comments in `ApplicationPolicy`, `BranchScope`, `EmployeeScope`, `LaundryBatchPolicy`, `laundry.rake`, `dashboard/_analytics_section` | Text only, no read |

### Verification

* **Focused runs after each migration:**
  * Laundry: 104 examples, 0 failures.
  * Onboarding: 111 examples, 0 failures.
  * API session: 128 examples, 0 failures, 1 pending (pre-existing).
* **Full relevant set** (Step 1 + Step 2 specs, Organization & Access characterization, role, user and policy specs,
  security, API, permission matrix, Laundry, onboarding, scope and Finance depositor, transfer, till handover and
  daily reconciliation specs): 1346 examples, 9 failures, 1 pending **both before and after**. The failing IDs are
  identical and all are in `permission-role-baseline-failures.txt`.
* `bin/rails zeitwerk:check`: all good. `git diff --check`: clean. RuboCop: no new offenses (2 pre-existing on
  `sessions_controller.rb:4`).
* **Contracts preserved:** permission group contents, `User#can?` / `#scope_for`, owner behaviour, business and
  branch scoping, scope escalation protection, API response shape, order and owner `[]`. No write path changed; no
  permission definitions moved; no second source of truth (the catalogue returns `PermissionRole`'s own arrays).
* **Database:** no migration or schema change; `PermissionRole` / `permission_roles` unchanged.

## Step 4 — PermissionGrants Migration Status

**Status:** COMPLETE (uncommitted; awaiting review). This corresponds to step 3 of the migration sequence (§10):
move the grant rules.

| | |
|---|---|
| **Old location** | `app/services/permission_grants.rb` — top-level `PermissionGrants` |
| **New location** | `app/services/organization_access/permission_grants.rb` — `OrganizationAccess::PermissionGrants`, next to `PermissionCatalog` and `Authorization`; same `Shifts::` / `Finance::` convention, no config |
| **How it moved** | `git mv` (history kept). The module body is byte-identical apart from the extra indentation of the `OrganizationAccess` wrapper: same constants (`ADMINISTRATIVE_PERMISSIONS`, `SCOPE_RANK`, `DEFAULT_SCOPE_RANK`), same 8 public methods, no private methods, same dependencies (`PermissionRole::ALL_PERMISSIONS`, `SCOPABLE_PERMISSIONS`, `.normalize_scope`, `User#owner?` / `#can?` / `#scope_for` / `#permission_role`) |
| **Compatibility** | `app/services/permission_grants.rb` is now the one-line alias `PermissionGrants = OrganizationAccess::PermissionGrants`. It is the **same module object**, not a wrapper, so there is no behaviour to drift. The alias stays until legacy-access removal (sequence step 6) |

### Callers migrated

All callers are internal to Organization & Access. The legacy name is now only used by the Step 1 characterization
spec, intentionally, to prove the alias.

| Caller | Call |
|---|---|
| `UserPolicy#permitted_attributes` (owner login fields, OA-S4/S5) and `#controls_account?` (OA-S8 and privilege hierarchy) | `covers?` ×2 |
| `PermissionRolePolicy#manageable?` (update/destroy, OA-S3) | `manageable_role?` |
| `Admin::PermissionRolesController#assign_user` / `#remove_user` (OA-S3) | `can_change_role?` ×2 |
| `Admin::PermissionRolesController#grants_ungrantable_permissions?` (escalation, scope escalation) | `ungrantable`, `overbroad_scopes` |
| `Admin::UsersController#assign_role` (OA-S1/S3 via the employee form) | `can_change_role?` |
| `app/views/admin/users/_form.html.erb` (assignable-role list) | `manageable_role?` |

Code comments that mention "PermissionGrants" generically were left as they are.

### Tests added

`spec/services/organization_access/permission_grants_spec.rb` (15 examples):

* the legacy name is the same module, so the 35 Step 1 decision-table examples now exercise the new location
* public interface and constants unchanged
* the full scope-breadth matrix (actor `self`/`branch`/`area`/blank/`business` × role scopes, legacy names)
* changing an existing role (within → within allowed; within ↔ broader denied; same permissions at a broader scope
  denied; self-assignment denied)
* the business-isolation split: the module itself does **not** check businesses. A foreign role or target passes
  the module, and isolation is enforced by callers (`current_user.business` lookups, 404) and by the `User`
  same-business validation, which is pinned here. This is existing, intentional behaviour, documented and not
  "fixed"

### Security guarantees preserved

Each guarantee is protected by an existing spec that ran green before and after:

| Guarantee | Protected by |
|---|---|
| OA-S1 self-modification | `organization_access_security_spec` "OA-S1" |
| OA-S2 business scoping (foreign role, user, branch → 404 / invalid) | security spec "OA-S2", `view_and_role_scope_spec` "9. cross-business", new isolation examples |
| OA-S3 role assignment and escalation | security spec "OA-S3", Step 1 G1, new change-role examples |
| OA-S4/S5 owner protection | security spec "OA-S4/S5", `scope_hierarchy_spec` "Case D", G1 owner examples |
| OA-S6 account claim | security spec "OA-S6", `registration_service_spec` |
| OA-S7 branch managers | security spec "OA-S7" (`Branch` validation; not a PermissionGrants rule) |
| OA-S8 employee-management scope and privilege hierarchy | `scope_hierarchy_spec` "OA-S8" and "privilege hierarchy" Cases B–E |
| Role permission-scope escalation | `view_and_role_scope_spec` "role permission scope", new matrix |

### Verification

* **PermissionGrants-related set** (Organization & Access characterization, boundary specs, security, user and role
  policies, admin users, role localization): 336 examples and 4 failures **before** → 351 and 4 **after** (+15
  new). The failing IDs are identical, all role-localization baseline failures.
* **Broad relevant set** (the above plus permission matrix, API, Laundry, onboarding, scopes, Finance depositor,
  transfer, till handover and daily reconciliation, admin branches): 1416 examples, 9 failures, 1 pending. The
  failing IDs are **identical** to Step 3 and all are in `permission-role-baseline-failures.txt`. **No new
  failures.**
* `bin/rails zeitwerk:check`: all good. `git diff --check`: clean. RuboCop: no new offenses (8 pre-existing in
  `admin/users_controller.rb`, untouched lines).
* **No API or web behaviour change:** same results, routes, flashes and statuses (request specs green).

### Remaining legacy access

* `PermissionGrants` (top-level alias): kept for compatibility; used only by the Step 1 characterization spec.
  Remove in sequence step 6.
* `PermissionRole` is **untouched**: same model, table (`permission_roles`), constants and validations. No
  migration or schema change. OA-D3, R-L4 and audit behaviour are untouched (D1–D3).

## Step 5 — Role Operations Migration Status

**Status:** COMPLETE (uncommitted; awaiting review). This corresponds to steps 4–5 of the migration sequence (§10):
role operations move into Organization & Access services, and the controllers delegate to them.

### Services created

All live in `app/services/organization_access/`. They follow the repository's service convention: ids in, loaded
inside `actor.business`, a per-class `Result(ok, record, error)`, no HTTP. None of them audits (D1).

| Service | Responsibility | Authorization (existing mechanisms) |
|---|---|---|
| `RoleAssignmentRule.decide(actor:, user:, role_id:)` → `Decision(allowed, role)` | **The single authoritative role-change decision (R-H2).** Resolves the role inside `actor.business` (unknown or foreign id → denied, OA-S2). Blank id = remove | `PermissionGrants.can_change_role?` (manage_roles, never self, never the owner, current and new role within the actor's permissions and scopes — OA-S3/S4/S5) |
| `ChangeUserRole.new(user_id, actor:, role_id:)` | Assign or remove a role and persist it (role screen). Loads the user in `actor.business` (foreign → `RecordNotFound`, 404). `update!` as before (`RecordInvalid` still raises) | `RoleAssignmentRule` |
| `CreateRole.new(actor:, attributes:)` | Build in `actor.business` (a supplied `business_id` is ignored), grant check, save | `PermissionRolePolicy#create?`, `RoleGrantCheck` |
| `UpdateRole.new(role_id, actor:, attributes:)` | Load in `actor.business`, check manageability of the role as it stands, assign, grant check (only **added** permissions), save | `PermissionRolePolicy#update?`, `RoleGrantCheck` |
| `DeleteRole.new(role_id, actor:)` | Load in `actor.business`; never delete a role with users (`:has_users`); destroy | `PermissionRolePolicy#destroy?` |
| `RoleGrantCheck.violations?(actor:, role:, previous_permissions:)` | Escalation guard shared by create and update (moved verbatim from the controller): validate first, then `cannot_grant` / `scope_too_broad` errors | `PermissionGrants.ungrantable` / `.overbroad_scopes` |

### Callers migrated

| Controller action | Before | After |
|---|---|---|
| `Admin::PermissionRolesController#create` | build + `authorize record` + private `grants_ungrantable_permissions?` + save | `authorize PermissionRole` (`create?` only checks `manage_roles`; no throwaway record is built on `business.permission_roles`) → `CreateRole` |
| `#update` | `authorize` + assign + grant check + save | `authorize @permission_role` → `UpdateRole(@permission_role.id)` |
| `#destroy` | `authorize` + `users.any?` + destroy | `authorize` → `DeleteRole` (`:has_users` → same alert) |
| `#assign_user` / `#remove_user` | `authorize :update?` + user find + `can_change_role?` + `update!` | `authorize :update?` → `ChangeUserRole` |
| `Admin::UsersController#assign_role` (create/update employee form) | own copy: `find_by` in business + `can_change_role?` | `RoleAssignmentRule.decide`. The form-specific "unchanged value is a no-op" and the staging of the role on the (possibly unsaved) user stay in the adapter |

The controllers keep only params, Pundit `authorize`, the service call, flash, redirect and render. A service
returning `:not_authorized` (unreachable after `authorize`) raises `Pundit::NotAuthorizedError`, the same denial
flow. The private `grants_ungrantable_permissions?` was removed.

### Duplicated logic consolidated

The role-assignment escalation decision existed twice (`PermissionRolesController#assign_user` / `#remove_user` and
`UsersController#assign_role`). It now exists **once**, in `RoleAssignmentRule`, and both entry points use it.
`spec/requests/admin/role_assignment_entry_points_spec.rb` proves the same outcome from both screens:

* within authority → assigned
* permission escalation → refused
* broader scope → refused
* moving off a higher role → refused
* owner → refused
* self → unchanged
* foreign role → never assigned (404 on the role screen, refusal on the form)

The escalation check for role definitions (create/update) likewise exists once, in `RoleGrantCheck`.

### Tests added (41 examples)

* `role_assignment_rule_spec.rb` (10)
* `change_user_role_spec.rb` (7, including "no audit record", D1)
* `role_definition_services_spec.rb` (17: create, update and delete — valid, invalid permissions, permission
  escalation, scope escalation, unmanageable role, has users, cross-business `business_id` / role id, owner)
* `spec/requests/admin/role_assignment_entry_points_spec.rb` (7, parity)

All are green in default and two random orders.

### Security guarantees preserved

OA-S1–S8, the privilege hierarchy (Cases B–E), role permission-scope escalation, owner protection, self-assignment
restrictions and cross-business isolation are all green in the unchanged specs:

* `organization_access_security_spec`
* `organization_access_scope_hierarchy_spec`
* `organization_access_view_and_role_scope_spec`
* `user_policy_spec`
* `permission_role_policy_spec`
* `permission_matrix_verification_spec`
* the Organization & Access characterization suite (including "role assignment is NOT audited" and the OA-D3
  accountant-defaults example)

### Verification

* **Role-operation set:** Organization & Access characterization, boundary and service specs, security, policies,
  admin users, branches and role localization, permission matrix, sidebar, API, Laundry, onboarding, scopes and
  Finance depositor, transfer, till and daily reconciliation.
  * Before: 1445 examples, 11 failures, 1 pending.
  * After: 1486 examples, 11 failures, 1 pending (+41 new).
  * The failing IDs are **identical**, all in `permission-role-baseline-failures.txt`. **No new failures.**
* `bin/rails zeitwerk:check`: all good. `git diff --check`: clean. RuboCop: no new offenses (the 8 pre-existing in
  `admin/users_controller.rb`, untouched lines).
* **No API or web change:** same routes, params, redirects, flash keys and status codes (422 re-render, 404 for
  foreign records, `flash.not_authorized` on refused assignment).

### Remaining legacy access

* `PermissionGrants` top-level alias (Step 1 spec only), to be removed in sequence step 6.
* Policies (`UserPolicy`, `PermissionRolePolicy`) and the users form's assignable-role list call
  `OrganizationAccess::PermissionGrants` directly. That is the authorization mechanism itself, not duplicated role
  logic.
* `PermissionRole` is **untouched**: same model, table, constants, defaults (OA-D3 preserved) and validations. No
  migration or schema change. No audit logging added; R-L4 untouched.

## Step 6 — Legacy Access Cleanup Status

**Status:** COMPLETE (uncommitted; awaiting review). This corresponds to steps 6–7 of the migration sequence (§10):
remove legacy access and enforce the boundary.

### Inventory and classification

Every remaining reference to `PermissionRole`, `PermissionGrants`, `permission_role(s)` and the Organization &
Access role services was reviewed caller by caller:

| Class | References |
|---|---|
| **A. Organization & Access internal** | **Models:** `PermissionRole`, `User`, `Business`. **Boundary:** `app/services/organization_access/**`. **Policies:** `PermissionRolePolicy`, `UserPolicy`. **Admin:** `Admin::PermissionRolesController` and views, `Admin::UsersController`, `admin/users/_form` (assignable roles) and `show` (role name), `admin/branches/_employees` and `admin/dashboard/index` (role-name display on Organization & Access admin screens) |
| **B. Valid cross-domain interface** | `OrganizationAccess::PermissionCatalog` (Laundry gate, onboarding policy); `OrganizationAccess::Authorization` (API login payload); `User#can?` / `#scope_for` / `#management_sidebar?` everywhere. `includes(:permission_role)` preloads (Finance ×5, admin branches and dashboard) feed `User#can?` (I11) |
| **C. Legacy, removed** | `app/services/permission_grants.rb` — the top-level `PermissionGrants = OrganizationAccess::PermissionGrants` alias |
| **D. Test-only compatibility** | The Step 1 characterization spec (45 call sites) and one Step 4 example used the alias. They now call `OrganizationAccess::PermissionGrants`. Assertions unchanged; the Step 4 example now asserts the alias is gone |
| **E. Must remain unchanged** | `layouts/_sidebar` (UI shell: role-screen nav entry and current role label); `lib/tasks/attendance.rake` (R-L4, D3); `lib/tasks/laundry.rake` (message text); `dashboard/_analytics_section` (ERB comment text); `db/seeds.rb`; `db/migrate/*` (frozen history) |

### Removed

* The top-level `PermissionGrants` alias. It was not an external contract: an internal Ruby constant, never part
  of the API (`docs/api`) or any route, and used only by the two specs above. `Object.const_defined?(:PermissionGrants)`
  is `false`, including under eager loading.

### Intentionally retained (direct internal access)

`UserPolicy` (`covers?` ×2), `PermissionRolePolicy` (`manageable_role?`) and the users form's assignable-role list
(`manageable_role?`) call `OrganizationAccess::PermissionGrants` directly. They are Organization & Access internals,
and the call **is** the authorization rule. A wrapper would add an abstraction layer with no benefit, so they stay
as they are.

### Enforcement

`spec/architecture/permission_role_boundary_spec.rb` is a plain RSpec architecture test, with no new gems and no
Rails configuration:

* It scans `app/**` and `lib/**` (`.rb`, `.erb`, `.rake`), ignoring full-line Ruby comments and ERB comments.
* It fails on any reference to the following outside an explicit allow-list:
  * `PermissionRole` (not `PermissionRolePolicy`)
  * `PermissionGrants`
  * `permission_role(s)`
  * the Organization & Access role services (`RoleAssignmentRule`, `ChangeUserRole`, `CreateRole`, `UpdateRole`,
    `DeleteRole`, `RoleGrantCheck`)
* `.includes(:permission_role)` preloads are allowed anywhere.
* Every allow-list entry carries its reason. A second example fails if an allow-listed file no longer needs its
  exception, so the list can only shrink.
* `User#can?`, `#scope_for`, `PermissionCatalog`, `Authorization` and `PermissionRolePolicy` are **not** banned.
* **Verified:** a temporary probe file in `app/services/` reading `PermissionRole::PERMISSION_GROUPS` made the spec
  fail with its file and line. The probe was removed.

### Tests and baseline

* **Pilot set:** Step 1 characterization, Step 2–5 boundary and service specs, role/user policies, security, API,
  Laundry, onboarding, Finance, admin users, branches and role screens, permission matrix, parity spec, plus the
  new architecture spec.
  * Before: 1486 examples, 11 failures, 1 pending.
  * After: 1489 examples, 11 failures, 1 pending (+3 architecture examples).
  * The failing IDs are **identical**, all in `permission-role-baseline-failures.txt`. **No new failures.**
* `bin/rails zeitwerk:check`: all good. `git diff --check`: clean. RuboCop: no offenses in the changed specs.

### Security, behaviour and database

* All green in unchanged specs:
  * OA-S1–S8
  * the privilege hierarchy (Cases B–E)
  * role permission-scope escalation
  * owner protection and self-assignment restrictions
  * cross-business isolation
  * role create/update/delete and assign/remove behaviour
* The following are unchanged: web role management, the API login `permissions` payload (G2/G3), Laundry and
  onboarding gates, and Finance depositor eligibility.
* No application code behaviour changed. The only production change is the deleted alias file.
* No migration or schema change. `PermissionRole` / `permission_roles` are untouched: associations, validations and
  constants.

### Remaining PermissionRole migration work

* **Physical move of the model** (and, optionally, the catalogue constants into `PermissionCatalog` with model
  aliases). The model, table and constant names stay fixed (D4); historical data migrations depend on the constant.
* **Optional:** `User#role_name` (I6) to retire the role-name display exceptions. It requires a `User` model change.
* **Open:** Q3 (owner `permissions` in the API), Q4 (named capability checks vs group membership), Q5 (final physical
  structure / Packwerk), Q6 (moving access-scope infrastructure after the Workforce membership contract).
* **Separate tasks, not pilot scope:** OA-D3, role-change auditing (D1), R-L4.

## 7. Proposed target structure

The repository already uses namespaced service folders under `app/services/` (`Finance::`, `Inventory::`,
`Shifts::`, `Payroll::`, `Approvals::`), which Zeitwerk autoloads without configuration. The pilot follows that
convention instead of creating a new root:

```
app/services/organization_access/
  authorization.rb          # I1, I2, I5 — effective-permission evaluation
  permission_catalog.rb     # I3, I4 — read-only catalogue (delegates to PermissionRole constants first)
  permission_grants.rb      # I10 — moved from app/services/permission_grants.rb (+ top-level alias)
  role_assignment.rb        # I8
  role_creator.rb           # I9
  role_updater.rb           # I9
  role_destroyer.rb         # I9
app/models/permission_role.rb   # stays: table, associations, validations, normalization
```

A later move to `app/domains/organization_access/` or Packwerk `packs/` (open question 9 in the readiness document)
would be a mechanical relocation of this namespace. It is **not** part of this pilot.

## 8. File-by-file plan

| File | Action | Notes |
|---|---|---|
| `app/models/permission_role.rb` | **KEEP** (later **REFACTOR**) | Constant name, table and validations unchanged. At step 4, the catalogue constants may be extracted into `PermissionCatalog` with the model constants kept as aliases, which 16 data migrations and the views require |
| `app/models/user.rb` | **REFACTOR** (body only) | `can?`, `scope_for` and `management_sidebar?` delegate to `OrganizationAccess::Authorization`. Add `role_name`. Association and validation unchanged |
| `app/models/business.rb` | **KEEP** | |
| `app/services/permission_grants.rb` | **MOVE** → `organization_access/permission_grants.rb` + **WRAP** | Keep `PermissionGrants = OrganizationAccess::PermissionGrants` until step 6 |
| `app/services/organization_access/{authorization,permission_catalog,role_assignment,role_creator,role_updater,role_destroyer}.rb` | **NEW** (future) | **No** role-change audit calls (D1). Behaviour identical to today, including OA-D3 (D2) |
| `app/controllers/admin/permission_roles_controller.rb` | **REFACTOR** | Thin: authorize → service → redirect/render; pass `role.id`. Same routes, flashes, status codes and redirects |
| `app/controllers/admin/users_controller.rb` | **REFACTOR** (role part only) | `assign_role` → `RoleAssignment`. **No** User/Employee changes |
| `app/controllers/admin/base_controller.rb` | **KEEP** | The gate stays; regrouping is a later Organization & Access step |
| `app/controllers/api/v1/sessions_controller.rb` | **REFACTOR** (one line) | `permissions:` via `Authorization.granted_permissions` — payload byte-identical |
| `app/policies/permission_role_policy.rb` | **KEEP** (namespace reference update) | Rules unchanged |
| `app/policies/user_policy.rb` | **KEEP** | |
| `app/policies/application_policy.rb`, `app/services/branch_scope.rb`, `app/services/employee_scope.rb` | **KEEP** (comment and constant reference → `PermissionCatalog`) | Access-scope infrastructure. The move is outside this pilot (depends on the Workforce membership contract) |
| `app/policies/employee_data_request_policy.rb`, `app/controllers/laundry/base_controller.rb` | **WRAP** | Switch to `PermissionCatalog.group(...)` — the only cross-domain code edits |
| `app/policies/laundry_batch_policy.rb` | **KEEP** | comments only |
| Finance `includes(:permission_role)` (5 sites), `admin/branches_controller.rb`, `admin/dashboard_controller.rb`, `till_handovers_controller.rb` | **KEEP** | Allowed preload (I11) |
| Views showing `permission_role&.name` (4) | **REFACTOR** (optional, low value) | → `role_name` |
| `app/views/admin/permission_roles/*`, `permission_role_form_controller.js` | **KEEP** | Organization & Access UI; constant references may switch to `PermissionCatalog` |
| `config/routes.rb` | **KEEP** | No route changes |
| `db/seeds.rb` | **KEEP** (optionally route through `RoleCreator` later) | |
| `lib/tasks/attendance.rake` | **KEEP** (defect logged, R-L4) | Out of scope |
| `db/migrate/*` | **KEEP** | Frozen history; the reason the constant can never be renamed |
| `spec/factories/permission_roles.rb`, `spec/support/*` helpers | **KEEP** | |
| `PermissionGrants` top-level alias, direct `PermissionRole::PERMISSION_GROUPS` use outside Organization & Access | **DELETE LATER** (step 6) | |

### 8.1 Database (no schema change)

**No schema change is needed.** `permission_roles` (business-scoped, unique `[business_id, name]`, foreign key to
`businesses`), `users.permission_role_id` (foreign key `on_delete: :nullify`) and the jsonb columns stay as they are.
Moving behaviour into services changes no column, index or constraint.

No schema problem was found that blocks the pilot. Data observations, none of which needs a migration:

* `seeds.rb` still writes the legacy scope `business_wide`. It is normalized on save, so it works as designed.
* The defects OA-D3 (accountant defaults) and R-L4 (rake task) are code defects, not schema defects.

## 9. Cross-domain contracts after migration

| Party | Contract |
|---|---|
| **User** | `User#can?`, `#scope_for`, `#management_sidebar?` and `#role_name` are the only permission entry points other domains use. `users.permission_role_id` is written **only** by `OrganizationAccess::RoleAssignment`. The model validation (role in the same business) stays as a last line of defence |
| **Employee / Workforce** | Workforce never reads or writes roles. Onboarding gates use `PermissionCatalog.group(:employee_onboarding)`. Employee profile fields on `users` are untouched (User ≠ Employee; no split in this pilot) |
| **Branch** | No direct relationship. Branch scope comes from `scope_for` plus branch management columns, both consumed through `BranchScope` / `EmployeeScope` / `ApplicationPolicy` helpers, which are unchanged |
| **Authorization (all domains)** | Policies keep `can?(:perm)` via `ApplicationPolicy#can?`. Scope filtering keeps `filter_by_branch_scope` / `filter_by_data_scope`. The owner keeps every permission and `"business"` scope. No domain may evaluate `permissions` jsonb itself |
| **Inventory & Purchasing (Laundry)** | `PermissionCatalog.group(:laundry_operations)` plus `(:laundry_cost_reports)` |
| **Finance & Sales** | `eligible_depositor?` (`active?` and `can?(:create_till_deposit)`); may preload `:permission_role` |
| **API clients** | `POST /api/v1/auth/login` payload `permissions` is unchanged: same values, same `[]` for the owner and for users without a role |

## 10. Migration sequence

Each step ships separately, keeps the application fully working, and must pass the success criteria (§12) before
the next.

| Step | Change | Behaviour change |
|---|---|---|
| 0. Characterize | **Done.** 69 + 49 Organization & Access characterization tests, 83 security tests; baseline failing IDs recorded; REQUIRED gaps G1, G2, G3, G4, G5, G7 green against unchanged code | none |
| 1. Introduce boundary | Add `OrganizationAccess::Authorization` and `PermissionCatalog`, delegating to the current model and constants. Add `User#role_name`. No caller changes | none |
| 2. Route reads through the boundary | `User#can?` / `#scope_for` bodies delegate to `Authorization`. Laundry and onboarding use `PermissionCatalog.group`. The API session uses `granted_permissions` | none |
| 3. Move grant rules | `PermissionGrants` → `OrganizationAccess::PermissionGrants` with a top-level alias | none |
| 4. Migrate internal implementation | Role lifecycle and assignment services (`RoleCreator`, `RoleUpdater`, `RoleDestroyer`, `RoleAssignment`). The catalogue moves into `PermissionCatalog`, with model constants kept as aliases | none (D1: no audit added; D2: OA-D3 preserved) |
| 5. Migrate controllers and policies | `Admin::PermissionRolesController` and the role part of `Admin::UsersController` call the services. Policies reference `OrganizationAccess::PermissionGrants` | none (same routes, flashes, statuses) |
| 6. Remove legacy access | Remove the `PermissionGrants` alias and `PermissionRole::PERMISSION_GROUPS` use outside Organization & Access | none |
| 7. Enforce boundary | A spec, or Packwerk later, failing on `PermissionRole` references or `permission_role_id` writes outside an allow-list (Organization & Access files, migrations, seeds, factories, specs, documented preloads) | none |

## 11. Risks

| ID | Level | Risk | Mitigation |
|---|---|---|---|
| R-H1 | HIGH | **Authorization regression in `User#can?` / `#scope_for`.** About 570 call sites in every domain; a delegation slip (e.g. owner short-circuit, symbol vs string, nil role) silently opens or closes access | Keep the method bodies semantically identical; full-suite run with an unchanged baseline; permission matrix and security specs; owner and no-role examples |
| R-H2 | HIGH | **Escalation guards lost while moving assignment and lifecycle.** `can_change_role?` runs in **two** controllers today; extracting one and missing the other reopens OA-S3 (self-assignment, owner, above-own permissions, cross-business role) | `RoleAssignment` becomes the single path; security specs (83) must stay green; enforcement spec in step 7 |
| R-M1 | MEDIUM | `grants_ungrantable_permissions?` depends on running **after** `role.validate` (so defaults and normalization apply first) and on `previous_permissions` (only *added* permissions are checked). Reordering changes outcomes | Port verbatim into `RoleCreator` / `RoleUpdater`; the characterization defaults and scope examples pin it |
| R-M2 | MEDIUM | **Business scoping.** Today `current_user.business.permission_roles.find` gives a 404 across businesses; services must load by `id` inside `actor.business`, never accept a preloaded record | CLAUDE.md "Services accept IDs" rule; cross-business specs |
| R-M3 | MEDIUM | **Scope vocabulary drift.** `SCOPE_OPTIONS` / `normalize_scope` are shared by `ApplicationPolicy`, `BranchScope` and `PermissionGrants`. Two sources of truth would let the UI, validation and ranking disagree | `PermissionCatalog` delegates to the same frozen constants until step 6 |
| R-M4 | MEDIUM | **Permission-matrix behaviour.** It already has 3 baseline failures, which can mask a new failure in the same file | Compare failing example IDs, not counts |
| R-M5 | MEDIUM | **Controller coupling in `Admin::UsersController`.** The role assignment is interleaved with the user create/update flow, which mixes User and Employee data | Extract only `assign_role`; do not touch the attribute tiers or employee fields |
| R-L1 | LOW | API payload change (owner `permissions` `[]`) | Add the owner and role-holder API examples first (§6) |
| R-L2 | LOW | Renaming the constant breaks 16 data migrations and about 150 specs | Explicitly out of scope; constant kept |
| R-L3 | LOW | Preload removal causing N+1 in Finance | Preloads kept (I11) |
| R-L4 | LOW | **Existing defect:** `lib/tasks/attendance.rake` filters `permission_roles.role = "super_admin"`, but that column does not exist, so the fallback path raises. It only runs when no `actor_id` is given | Documented; not fixed in the pilot |
| R-L5 | LOW | Translation baseline failures (`manage_bank_disputes`) hide catalogue i18n regressions | Compare failing example IDs |

## 12. Success criteria

The migration is successful only when **all** of these hold:

1. All `spec/characterization/organization_access/*` examples pass, especially `permission_roles_spec` and
   `access_contracts_spec`.
2. All `spec/requests/security/organization_access_*` examples pass (no escalation, no scope escalation, no
   cross-business role, owner protected).
3. `permission_role_spec`, `permission_role_policy_spec`, `user_policy_spec`, `user_spec`, `employee_scope_spec`,
   `branch_scope_spec` and `registration_service_spec` pass.
4. Full suite: **the set of failing example IDs is identical to the baseline** (currently 87 failures). No new
   failure in `permission_matrix_verification_spec`.
5. No cross-business access: a role of another business is never visible, editable or assignable (404 / refusal
   unchanged).
6. No scope escalation: `scope_too_broad` and `cannot_grant` behaviour unchanged.
7. API contracts unchanged: `POST /api/v1/auth/login` and `DELETE /api/v1/auth/logout` responses are identical,
   including `permissions`; `docs/api/openapi.yaml` needs no change.
8. Web behaviour unchanged: same routes, redirects, flash keys, HTTP statuses and rendered role screens.
9. No database migration; `db/schema.rb` unchanged; model `PermissionRole` and table `permission_roles` unchanged (D4). Preserved behaviour: role changes still create no audit records (D1); the accountant-defaults defect OA-D3 still reproduces (D2); `lib/tasks/attendance.rake` untouched (D3).
10. No behaviour change in other domains (Laundry and onboarding gates identical).
11. Step 7 enforcement spec green: no `permission_role_id` writes or `PermissionRole` references outside the
    allow-list.

## 13. Rollback strategy

* Every step is one small commit (or PR) with no schema change, so `git revert <commit>` fully rolls it back. No
  data is touched.
* Steps 1–3 are additive (new boundary, delegation, aliases). Rolling back means reverting the delegation commit;
  the legacy path is never deleted before step 6.
* Steps 4–5 keep the old controller logic reachable until the service path has passed the full suite once on
  `main`.
* Step 6 (removals) is the only step that cannot run alongside the old path. It happens last, after a release cycle
  with the boundary in production.
* Trigger: any new failing example ID in the security, characterization or permission-matrix specs, or any
  production authorization incident. Revert first, then investigate.

## 14. Open questions

Q1, Q2 and the R-L4 question are resolved (see §1.1, decisions D1–D3). The remaining question IDs are kept stable.

| # | Question | Why it matters |
|---|---|---|
| Q3 | Should the API expose effective permissions for the owner (currently `[]`)? | Mobile clients may rely on `[]`; changing it is an API contract change |
| Q4 | Is `PermissionRole::PERMISSION_GROUPS` group membership a public contract for other domains, or should Laundry and onboarding get named capability checks (e.g. `Authorization.any_in_group?`)? | Determines the shape of I3 |
| Q5 | Final physical structure: `app/services/organization_access/` (proposed) vs `app/domains/` vs Packwerk | Readiness open question 9; affects step 7 enforcement tooling |
| Q6 | Should the access-scope infrastructure (`EmployeeScope`, `BranchScope`, `ApplicationPolicy` helpers) move with Organization & Access before or after the Workforce membership contract is defined? | It consumes `ShiftAssignment` / `BranchMembership` (Workforce) |
