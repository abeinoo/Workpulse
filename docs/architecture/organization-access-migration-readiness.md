# Organization & Access — Migration Readiness Audit

**Type:** read-only audit (no application code, routes, APIs, schema or tests changed).
**Code baseline:** branch `feature/api-foundation` @ `a4e9a96`.
**Architecture reference:** `docs/architecture/module-boundaries.md` (six-domain model; User ≠ Employee).
**Audience:** engineers and reviewers deciding when and how to start migrating the first domain.

### Method

* **Code review:** every file listed in §3, plus the models, policies, routes and specs.
* **Security probes:** real in-process HTTP requests against the **test database**, run inside a transaction that was
  always rolled back. Two runner scripts were used, kept in a scratchpad outside the repository. **Nothing persisted,
  no repository file was created or changed.** Findings marked **PROVEN** were reproduced this way; findings marked
  **CODE** come from code reading only.
* **Test run:** the 26 spec files related to this domain were executed (read-only).

---

## 1. Executive summary

Organization & Access is **structurally the easiest domain to isolate**, but it is **not ready to migrate**.

**Structurally easy.** The domain is small: 5 models, ~10 controllers, 4 services and 3 policies. Its API surface is
two endpoints, and cross-business isolation holds at the controller level. Every admin controller loads records
through `current_user.business`, and a control probe from another business got 404.

**Not ready: blocking security findings.** Six confirmed account-level privilege and takeover issues live in the
account-administration paths this domain owns:

* **Self-escalation.** Any user who can open the admin area — including a user holding only `view_attendance` — can
  give themselves any role, even one from **another business**.
* **Owner takeover.** A user with only `manage_employees` can reset the business owner's password, deactivate the
  owner, or grant full-access roles without `manage_roles`.
* **Unauthenticated account claim.** The public sign-up lets anyone who knows a not-yet-registered employee's phone or
  email take over that account, and it reveals which phones/emails exist.

These must be fixed (as a separately approved task, like the previous security-hardening phase) before any
migration step touches these files.

**Not ready: structural blockers.**

* User and Employee share one model, one table and one admin form (`admin/users`).
* Authorization scopes depend on Workforce's `ShiftAssignment`.
* `User` and `Branch` destroy cascades delete other domains' records (attendance, payroll, advances…).
* The permission catalogue and the admin-area gate enumerate every domain's permissions.

**Recommendation:** fix the security findings and add characterization coverage for account administration first
(§12 steps 0–1). Then migrate the low-coupling parts:

* `PermissionRole`
* `UserAuditLog`
* `Approvals::SelfApproval`
* the role and settings screens
* `BusinessDay` (to the shared kernel)

Keep `User`, `admin/users` and `admin/branches#show` legacy until the Workforce boundary exists.

## 2. Domain ownership

| Owned by Organization & Access | Not owned (boundary) |
|---|---|
| `Business` (incl. storage of all business settings) | Employee profile/employment data → **Workforce** (stored on `users` today) |
| `Branch` (incl. branch/area manager assignment) | `ShiftAssignment` / branch membership → **Workforce** |
| `User` **account** concern: credentials, login identifiers, `active`, `permission_role_id`, `business_id`, `preferred_locale` | Attendance-channel flags `allow_mobile_attendance` / `allow_biometric_attendance` → **Attendance & Payroll** |
| `PermissionRole` (catalogue, dependencies, data scopes) | `WarehouseAssignment` (warehouse access) → **Inventory & Purchasing** |
| `UserAuditLog` | `PosTerminal` (edited on the branch form) → **Finance & Sales** |
| Access scopes: `EmployeeScope`, `BranchScope`, `ApplicationPolicy` scope helpers (rules) | Pundit / Devise mechanisms → **Infrastructure** |
| Segregation of duties: `Approvals::SelfApproval` | `AuditLog` → **Infrastructure** |
| Authentication flows: web session, API session, registration (account claim), password change/reset | `BusinessDay` → **Shared kernel** |

### How the code represents User ↔ Employee today

* There is **one model (`User`) and one table (`users`)**; no `Employee` model exists.
* `User` mixes three concerns:
  * **Account:** Devise modules `database_authenticatable, registerable, recoverable, rememberable`;
    `active_for_authentication?`; `can?`; `scope_for`; `owner?`; `manages_branch?` / `manages_area?`.
  * **Employee:** `employee_code` generation (`before_create :assign_employee_code`, advisory lock), job-title
    catalogue validation, profile completion, birthday, date of birth, department.
  * **Other domains:**
    * `effective_shift_assignment_on` / `effective_branch_on` → Workforce (`Shifts::AssignmentResolver`)
    * `inventory_warehouse_ids` → Inventory & Purchasing
    * `eligible_depositor?` → Finance & Sales
* **"Employee without a login"** is a `users` row with blank `encrypted_password`, created by admin
  (`admin/users#create`) or by onboarding approval (`EmployeeDataRequests::EmployeeAttributes` → `User.new(...)`).
  The UI calls it "Pending Registration".
* **"User without Employee"** is not modelled. The owner and any administrator are ordinary `users` rows and are
  treated as employees by `EmployeeScope` (business-wide = every business user except the viewer).
* **`admin/users`** edits account fields (`email`, `phone_number`, `active`, `permission_role_id`), employee fields,
  and inventory warehouse access in **one form** (`user_params`).

## 3. Component inventory

Legend for "moves cleanly": **Yes** / **After refactor** / **No (legacy for now)**.

### 3.1 Models

| File | Responsibility | Dependencies | Moves cleanly | Known coupling |
|---|---|---|---|---|
| `app/models/business.rb` (239 lines) | Tenant, currency/timezone, settings (columns + serialized JSON), next employee code | `Attachable`; 60+ `has_many` to every domain (mostly `dependent: :destroy`) | After refactor | Inverse associations to all domains; stores AP/WF/IP/FS settings; `next_employee_code` is a Workforce rule |
| `app/models/branch.rb` (74) | Branch, type enum, geofence, managers | `branch_manager`/`area_manager` → `User`; `has_many` shift_assignments, attendance_records (**destroy**), payroll_periods (**destroy**), expenses…(restrict), pos_terminals (nested attributes), towel ledger/transfers, laundry batches | After refactor | Cascade-destroys AP data; nested write into FS (`pos_terminals`); laundry scope `laundry_transfer_eligible`; no manager-business validation (§7) |
| `app/models/user.rb` (308) | Account + employee + helpers (see §2) | Devise; `permission_role`, `department`; `has_many` warehouse_assignments, salary_profiles, shift_assignments, attendance_records, employee_requests, advances, payroll_entries, employee_obligations, performance reviews/observations (**all `dependent: :destroy`**), `employee_insurance_profile` (destroy), `custody_accounts` (restrict) | **No (legacy for now)** | User ≠ Employee split; cascade deletes into WF/AP/IP; WF/IP/FS helper methods; no `permission_role` business validation (§7) |
| `app/models/permission_role.rb` (455) | Permission catalogue, groups, dependencies, defaults, scopes, workspace | `business`; `users` (nullify) | **Yes** (mechanical) | Catalogue lists every domain's permissions (central registry) |
| `app/models/user_audit_log.rb` (8) | Password change/reset audit | `actor`, `target_user` | **Yes** | — |

### 3.2 Controllers

| File | Responsibility | Moves cleanly | Known coupling |
|---|---|---|---|
| `app/controllers/users/sessions_controller.rb` | Devise web login/logout (empty subclass) | Yes (auth infrastructure) | — |
| `app/controllers/users/registrations_controller.rb` + `Users::RegistrationService` | "Register" = claim a pre-created passwordless account by email/phone | After refactor | **Security OA-S6** |
| `app/controllers/profile/passwords_controller.rb` | Self password change (`update_with_password`, `bypass_sign_in`, audit) | Yes | No request spec |
| `app/controllers/admin/user_passwords_controller.rb` | Admin password reset (audit) | After refactor | **Security OA-S4**; no request spec |
| `app/controllers/admin/permission_roles_controller.rb` (115) | Role CRUD, assign/remove user (`manage_roles`; owner guard) | Yes | Only localization/permission-matrix specs |
| `app/controllers/admin/settings_controller.rb` | Business settings (`manage_settings`) | Yes (reads/writes only `businesses`) | Params include AP/WF/IP/FS settings |
| `app/controllers/admin/branches_controller.rb` (141) | Branch CRUD, manager assignment, terminals; `show` = branch dashboard | CRUD after refactor; `show` **No** | `show` reads `ShiftAssignment`, `AttendanceRecord`, `PayrollPeriod`, `EmployeeRequest`; writes `pos_terminals`; **OA-S7** |
| `app/controllers/admin/users_controller.rb` (195) | Employee CRUD **plus** `toggle_active`, `transfer_ownership`, role and warehouse assignment | **No (legacy for now)** | Mixed WF/OA/IP; **OA-S1…S5, S8** |
| `app/controllers/admin/base_controller.rb` | Admin-area gate: any of 13 permissions from 7 domains | No (legacy for now) | Knows every domain's admin permissions |
| `app/controllers/preferences_controller.rb`, `app/controllers/locale_controller.rb` | Locale preference (session + `preferred_locale`) | Yes | — |
| `app/controllers/api/v1/sessions_controller.rb` | API login/logout (cookie session), rate limited | After refactor (payload) | Payload reads `ShiftAssignment.current` (WF) and `allow_mobile_attendance` (AP) |
| `app/controllers/application_controller.rb` | `set_locale`, business timezone, `ensure_active_user`, `after_sign_in_path_for`, Pundit rescue | Infrastructure (stays) | Uses `current_user.business` for timezone/locale |

### 3.3 Services, policies, helpers, other

| File | Responsibility | Moves cleanly | Known coupling |
|---|---|---|---|
| `app/services/employee_scope.rb` (136) | Which users a viewer may see (self/branch/area/business) | After refactor | Reads `ShiftAssignment` via `BranchMembership` (WF) — needs the membership contract |
| `app/services/branch_scope.rb` (97) | Which branches a viewer may see | After refactor | Manager columns on `branches`; optional `ShiftAssignment` (WF); ids **not business-filtered** (§7 OA-S7) |
| `app/services/approvals/self_approval.rb` (30) | Creator ≠ approver rule | **Yes** | Used by WF, FS and IP approvals and `ExpensePolicy` |
| `app/services/users/registration_service.rb` | Account claim | After refactor | **OA-S6** |
| `app/services/branch_membership.rb` (41) | Branch membership from shift assignments | **Workforce** (not OA) | Consumed by `EmployeeScope` |
| `app/policies/application_policy.rb` (159) | Base Pundit policy + scope helpers (`filter_by_data_scope`, `filter_by_branch_scope`, `branch_within_scope?`, `resolved_branch_scope`, `for_accessible_warehouses`) | Mechanism → infrastructure; rules → OA | Used by all 69 policies |
| `app/policies/branch_policy.rb`, `permission_role_policy.rb` | `manage_branches` / `manage_roles` | Yes | — |
| `app/policies/user_policy.rb` | Employee management policy (index/show/update/destroy/reset_password/toggle_active/transfer_ownership) | After refactor | Mixed OA/WF; `update?` allows own record; no owner guards (§7) |
| `app/helpers/workspace_helper.rb` (344) | Sidebar/workspace navigation | Infrastructure (UI shell) | References every domain |
| `app/lib/business_day.rb` | Business day primitive | **Yes → shared kernel** | — |
| Views | `admin/branches/*` (12; `show` partials render attendance, payroll, requests, shifts), `admin/permission_roles/*` (5), `admin/settings/show`, `admin/user_passwords/edit`, `profile/passwords/edit`, `users/sessions/new`, `users/registrations/{new,edit}` | With their controllers | Branch show partials belong to other domains |
| Serializers / presenters / queries | None for this domain (API payloads are hand-built in `Api::V1::SessionsController#user_payload`) | — | — |
| Jobs / mailers | None (only an empty `ApplicationMailer`; Devise `recoverable` enabled but password routes skipped) | — | — |
| Routes | Devise (`skip: [:passwords]`), `/admin/branches`, `/admin/settings`, `/admin/permission_roles` (+ `assign_user`, `remove_user`), `/admin/users/:id/password`, `/admin/users/:id/{toggle_active,transfer_ownership}`, `/profile/password`, `/preferences/locale`, `/locale`, `/api/v1/auth/{login,logout}`, declared-only `/api/v1/{businesses,branches,users}` | — | — |

## 4. Model / table analysis

| Model | Associations (cross-domain in **bold**) | Callbacks | Validations | Scopes / concerns | Service deps |
|---|---|---|---|---|---|
| `Business` | `owner` (User); `has_many` branches, users, permission_roles, **employee_obligations, shifts, payroll_periods, biometric devices/logs, warehouses, suppliers, brands, product categories, products, goods receipts, purchase requests, stock documents, inventory movements, import batches, towel types/ledger/transfers, laundry batches, towel adjustments, services, laundry cost rates, departments, job titles, evaluation templates, performance reviews/observations, expense categories/types/tags, expenses, balance requests, recurring expenses, custody accounts/transactions, insurance profiles, branch revenues, sales imports, POS imports/terminals, bank statements** — almost all `dependent: :destroy` | none | name, timezone (recognized), working days, business-day start hour, locale, currency, advance %, overtime grace, payroll days, employee code start, barcode numbering, attendance thresholds ordered | `Attachable` (logo, stamp); `serialize :settings` | `next_employee_code` (WF rule) |
| `Branch` | `business`, `branch_manager`/`area_manager` (User), **`shift_assignments` (nullify), `attendance_records` (destroy), `payroll_periods` (destroy), `warehouse_supply` (destroy), expenses/allocations/recurring/custody/branch revenues/POS transactions/terminals (restrict), towel ledger/transfers, laundry batches (restrict)** | none | name, business, branch_type, geo fields | `active`, `for_business`, `laundry_transfer_eligible` (IP concept); enum `branch_type` | — |
| `User` | `business`, `permission_role`, **`department`, warehouse_assignments, salary_profiles, active_salary_profile, shift_assignments, attendance_records, employee_requests, advances, payroll_entries, employee_obligations, employee_insurance_profile, performance_reviews/observations** (all destroy), **custody_accounts** (restrict) | `before_create :assign_employee_code` (advisory lock) | attachments; locale; employee_code unique per business; **email, phone_number, identity_card_number unique globally**; names; password length; phone-or-email present; DOB not in future (uses `BusinessDay`); job title from catalogue | `active`, `inactive`, `by_department`, `birthday_on`; normalizers for email/phone/ID/code | `Shifts::AssignmentResolver` (WF) |
| `PermissionRole` | `business`, `users` (nullify) | `before_validation` (default permissions by role type; normalize scopes) | name unique per business; role_type; permissions valid; scopes valid; dependencies satisfied | `ordered`; enum `workspace` | — |
| `UserAuditLog` | `actor`, `target_user` (User) | none | action in `password_changed_self`, `password_reset_by_admin` | — | — |

Related tables: `businesses`, `branches`, `users`, `permission_roles`, `user_audit_logs`. There is **no join table**
for roles (a user has at most one role) and no branch-membership table (membership is derived from WF's
`shift_assignments`).

## 5. Cross-domain dependencies

Classification: **A** read-only lookup · **B** direct association · **C** direct database write · **D** service call ·
**E** callback · **F** event/job · **G** controller-level coupling · **H** policy/authorization coupling.

### 5.1 Organization & Access → other domains

| Source → Target | File | Class | What happens | Risk | Recommended future boundary |
|---|---|---|---|---|---|
| OA → WF | `app/services/employee_scope.rb`, `branch_membership.rb` | A, H | Employee visibility derived from active `ShiftAssignment`s | **High** | Membership contract defined by OA, implemented by WF |
| OA → WF | `app/services/branch_scope.rb` (`include_shift_assignments`) | A, H | Branch visibility for shift-assigned staff | Medium | Same contract |
| OA → WF/AP | `app/controllers/admin/branches_controller.rb#show` | G | Reads assignments, attendance, payroll period, requests for the branch dashboard | Medium | Move dashboard to Reporting / compose panels |
| OA → FS | `admin/branches` form, `Branch accepts_nested_attributes_for :pos_terminals` | C | Writes `pos_terminals` | Medium | FS interface for terminal editing (UI can stay embedded) |
| OA → AP/WF/IP/FS | `User has_many … dependent: :destroy` | B, E | Destroying a user deletes salary profiles, assignments, attendance, requests, advances, payroll entries, obligations, reviews, warehouse access | **High** | Deactivate, never delete; cascade removal replaced by domain decisions |
| OA → AP | `Branch has_many :attendance_records, :payroll_periods, dependent: :destroy` | B, E | Destroying a branch deletes attendance and payroll periods (may be blocked earlier by `restrict_with_error` on finance records) | **High** | Branch deactivation; restrict instead of destroy |
| OA → all | `Business has_many … dependent: :destroy` | B, E | Cascades across every domain (no route destroys a business today) | Low (no path) | Remove cascade intent when relocating associations |
| OA → WF | `User#effective_shift_assignment_on`, `#effective_branch_on` | D | Calls `Shifts::AssignmentResolver` | Medium | WF interface |
| OA → WF | `User#assign_employee_code`, `Business#next_employee_code`, `job_title_from_catalog` | E, A | Employee rules on the account model | Medium | Move to Employee stewardship (WF) |
| OA → IP | `User#inventory_warehouse_ids`, `warehouse_assignments` | A, B | Inventory access list on the user | Low | IP interface |
| OA → FS | `User#eligible_depositor?` | A | Finance rule on the account model | Low | FS interface |
| OA → IP | `Branch.laundry_transfer_eligible` | A | Laundry rule on the branch model | Low | IP-owned query |
| OA → AP/WF/IP/FS | `Business` settings accessors & `admin/settings` params | A, C (own table) | Stores other domains' configuration | Medium | `settings_for(business, domain)` |
| OA → all | `PermissionRole::PERMISSION_GROUPS`, `Admin::BaseController#require_admin_access!` | H | Central catalogue and gate enumerate all domains' permissions | Medium | Permission-group registration per domain; gate from registry |
| OA → WF/AP | `Api::V1::SessionsController#user_payload` | A, G | `ShiftAssignment.current` (check-in branches), `allow_mobile_attendance` | Medium | Compose from WF/AP interfaces |

### 5.2 Other domains → Organization & Access

| Source → Target | File(s) | Class | What happens | Risk | Recommended future boundary |
|---|---|---|---|---|---|
| WF → OA | `app/controllers/admin/users_controller.rb` (`user_params`) | C, H | Employee form writes account fields (`email`, `phone_number`, `active`, `permission_role_id`) | **High** (see OA-S1…S5) | OA account interface; WF edits employee fields only |
| WF → OA | `EmployeeDataRequests::EmployeeAttributes`, `Reviewer` | C | Onboarding creates `users` rows (no password) | Medium | `create_account_for(employee)` / Employee record |
| IP → OA | `admin/users` `assigned_warehouse_ids` | C | Inventory access written via the user form | Low | IP interface |
| All → OA | 137 FKs to `users`, 30 to `branches`; `business_id` everywhere | B | Ownership, attribution, tenancy | Low (expected) | Keep; read via OA interfaces |
| All → OA | 69 policies call `user.can?`, `scope_for`, `EmployeeScope`, `BranchScope`, `filter_by_*` | H | Authorization | Medium | Stable OA access interface; unchanged semantics |
| FS/IP/WF → OA | `Approvals::SelfApproval` in requests, expenses, balance requests, stock counts/issues, goods receipts, purchase requests | D | Segregation of duties | Low | Public OA interface (already a single service) |
| IP → OA | `Laundry::BaseController` reads `PermissionRole::PERMISSION_GROUPS` | A | Permission group lookup | Low | Registry lookup |
| AP → OA | `Attendance::*` read `users.allow_*` and business settings | A | Channel eligibility, thresholds | Low | AP-stewarded columns; settings interface |
| Infra → OA | `ApplicationController` (`current_user.business` timezone/locale), `WorkspaceHelper` | A | Request context, navigation | Low | Stays infrastructure |

## 6. Authentication analysis (current state — unchanged)

| Aspect | Current implementation |
|---|---|
| Web authentication | Devise session cookie (`database_authenticatable, registerable, recoverable, rememberable`); login key `login` = email or phone (`User.find_for_database_authentication`); inactive users rejected (`active_for_authentication?`); `ensure_active_user` signs out a deactivated session |
| Web login/logout | `Users::SessionsController` (Devise default); `sign_out_via :delete`; `expire_all_remember_me_on_sign_out` |
| API authentication | Same Devise session cookie; `POST /api/v1/auth/login` (`sign_in`), `DELETE /api/v1/auth/logout`; CSRF skipped for `/api/v1`; login rate-limited (10 / 5 min per IP+login, 60 / min per IP). Device tokens only for biometric punch (not OA) |
| Registration | Not self-signup of new businesses: "register" claims a **pre-created, passwordless** account by email/phone and signs in (`Users::RegistrationService`) — see OA-S6 |
| Password handling | bcrypt via Devise (stretches 12; 1 in test); length 6–128; self change requires current password (`update_with_password`) + audit; admin reset (`manage_employees`) + audit; **no password-reset-by-email flow** (routes skipped) |
| Remember me | Devise `rememberable` enabled |
| Lockout / throttling | Devise `lockable` not enabled; **web** login and registration are **not rate-limited** (API login is) |
| `current_user` | Devise/Warden helper; API controllers use the same helper |
| Business context | Always `current_user.business` (one business per user; `users.business_id`); timezone applied per request (`set_business_timezone`); never from params |
| Branch context | No "current branch". Resolved per feature: `BranchScope` (managed/area branches or business), `BranchMembership` (current shift assignment), explicit branch params validated against scope |
| Role resolution | `user.permission_role` (0..1); owner = `business.owner_id == user.id` |
| Permission resolution | `User#can?` → owner ⇒ all; else `permission_role.has_permission?`; data scope `User#scope_for` → owner ⇒ `"business"`, else role's configured scope (nil ⇒ hierarchy default) |
| Admin area gate | `Admin::BaseController#require_admin_access!` — any of 13 permissions (settings, roles, devices, obligations, employees (view/manage), branches, shifts, attendance (view/manage), salary profiles, evaluation templates, payroll view) |

Token authentication for React / React Native is **not** part of this audit (planned design in `docs/api/authentication.md`).

## 7. Authorization / security analysis

Cross-business isolation at the controller level holds for this domain's admin screens: `permission_roles`,
`branches`, `user_passwords`, `users` and `settings` all load through `current_user.business`, and a probe from
another business's owner requesting a Business-A branch received **404**. The findings below are within a business
(privilege) or through unvalidated foreign IDs.

| ID | Severity | Finding | Evidence | Status |
|---|---|---|---|---|
| **OA-S1** | **Critical** | **Self privilege escalation.** `admin/users#update` authorizes with `UserPolicy#update? = can?(:manage_employees) \|\| own_record?` and permits `permission_role_id` (and `active`). Any user who passes the admin-area gate — e.g. a role with only `view_attendance` — can PATCH their own record and assign themselves any role | Probe 1: `view_attendance`-only user → `PATCH /admin/users/:self {permission_role_id: full}` → 302; afterwards `can?(:manage_settings)` = true | **PROVEN** |
| **OA-S2** | **Critical** | **Cross-business role assignment.** `User belongs_to :permission_role` has no same-business validation, so a role id from another business is accepted (combinable with S1/S3) | Probe 2: same user assigned a Business-B role to self → 302, role business = B | **PROVEN** |
| **OA-S3** | **High** | **Role assignment without `manage_roles`.** Role assignment is gated by `manage_roles` + owner guard in `PermissionRolesController#assign_user`, but `admin/users#update` lets any `manage_employees` holder set `permission_role_id` on any business user | Probe 5: HR user (`view_employees`, `manage_employees`) gave another user the full-access role → 302 | **PROVEN** |
| **OA-S4** | **High** | **Owner account takeover.** `UserPolicy#reset_password? = can?(:manage_employees)` with no owner/privilege guard | Probe 3: HR user reset the owner's password → 302; owner's password changed | **PROVEN** |
| **OA-S5** | **High** | **Owner lockout / deletion.** `toggle_active` refuses the owner, but `update` permits `active` (owner deactivated); `UserPolicy#destroy?` has no owner guard (only self is refused) and destroy cascades (§5.1) | Probe 4: HR user set owner `active=false` → 302. Probe 6: `destroy?(owner)` = true (not executed) | **PROVEN** (update) / **CODE+policy** (destroy) |
| **OA-S6** | **High** | **Unauthenticated account claim + enumeration.** Public sign-up (`POST /users`) sets the password of any passwordless account matching an email/phone and signs the caller in — no proof of possession (no OTP, invite token or email confirmation). Distinct messages reveal whether an account exists / is registered. The spec suite treats claiming as intended (`registration_service_spec.rb`), so the missing verification is the gap | Probe: anonymous `POST /users` with a pre-created employee's phone → 302 and signed in (`GET /` 200); unknown phone → "No account found…"; second claim → "already been registered" | **PROVEN** |
| **OA-S7** | **Medium** | **Cross-business branch manager.** `branch_manager_id` / `area_manager_id` are not validated against the branch's business (form lists only own users, but params are trusted). The foreign user's `managed_branch_ids` then include the other business's branch. Reviewed consumers (`DailyReconciliationPolicy`, `RemainingDepositBalancePolicy`, finance dashboard, laundry branch pickers, attendance report API) intersect with the caller's own business, so **no data leak was found**; impact is integrity and distorted scopes for the foreign user | Probe 7: branch admin set a Business-B user as manager of a Business-A branch → 302; B user's `managed_branch_ids` include it | **PROVEN** (assignment); leak **not found** |
| **OA-S8** | **Medium** | **Employee edits ignore configured data scope.** `admin/users#set_user` loads from `current_user.business.users`, not `policy_scope(User)`; `UserPolicy#update?/destroy?/reset_password?/toggle_active?` check only the permission, so a branch-scoped `manage_employees` holder can edit/reset/deactivate any user of the business (including administrators) | `set_user`, `UserPolicy` | **CODE** |
| **OA-S9** | Low | **No throttling on web login and registration** (Devise `lockable` off; API login is rate-limited) — brute force / enumeration via web forms | `config/initializers/devise.rb`, absence of `rate_limit` | **CODE** |
| **OA-S10** | Low | Weak password floor (6 chars); `forgery_protection_origin_check = false` in production (documented earlier in `docs/api/authentication.md`) | Devise config, `production.rb` | **CODE** |

Checked and **not** vulnerable (for this domain): business-id manipulation on settings/roles/branches/passwords
(always `current_user.business`); cross-business `assign_user`/`remove_user` (scoped find); role removal from the
owner by a non-owner (guarded); API login enumeration (single "Invalid credentials" message); API session
business context (from the user only). The API-foundation fixes (S1/S2) and shift-assignment fixes are outside this
domain and unchanged.

## 8. API inventory

| Method | Route | Controller#action | Authentication | Authorization | Business scope | Branch scope | Response | Serializer | Tests | Other-domain deps | Class |
|---|---|---|---|---|---|---|---|---|---|---|---|
| POST | `/api/v1/auth/login` | `Api::V1::SessionsController#create` | none → sets Devise session cookie; rate-limited | credentials + `active` | user's own business (from record) | — | legacy `{success, data}`; 401 legacy error; 429 standard | hand-built `user_payload` | `sessions_spec` (6), characterization (15), rate limiting (7) | `ShiftAssignment.current` (WF), `allow_mobile_attendance` (AP) | **YELLOW** — payload must be composed from WF/AP interfaces; auth stays cookie-based |
| DELETE | `/api/v1/auth/logout` | `Api::V1::SessionsController#destroy` | session | signed in | — | — | legacy `{success, data: {message}}` | — | characterization | none | **GREEN** |
| GET/PATCH/PUT | `/api/v1/businesses/:id` | *(no controller)* | — | — | — | — | routing error | — | locked as unimplemented | — | **RED / not implemented** (keep undocumented until designed) |
| CRUD | `/api/v1/branches…` | *(no controller)* | — | — | — | — | routing error | — | locked | — | **RED / not implemented** |
| CRUD | `/api/v1/users…` (except nested salary profiles, AP) | *(no controller)* | — | — | — | — | routing error | — | locked | — | **RED / not implemented** — must not be built on the current mixed `admin/users` logic (OA-S1…S5) |

## 9. Test coverage

Executed read-only: 26 spec files, **710 examples, 9 failures** (all pre-existing, listed in `docs/api/baseline.md`).

| Area | Specs | Result |
|---|---|---|
| Models | `business_spec` (20), `business_attachments_spec` (25), `branch_spec` (21), `user_spec` (74), `user_attachments_spec` (49), `user_birthday_spec` (10), `user_job_title_spec` (5), `permission_role_spec` (146), `permission_role_translations_spec` (8 — **2 failing**) | ✅ except translations |
| Shared kernel | `lib/business_day_spec` (16) | ✅ |
| Policies | `branch_policy_spec` (12), `permission_role_policy_spec` (16), `user_policy_spec` (23) | ✅ |
| Services | `employee_scope_spec` (26), `branch_scope_spec` (15), `approvals/self_approval_spec` (6), `users/registration_service_spec` (14) | ✅ |
| Requests | `admin/branches_spec` (18), `admin/settings_spec` (4), `admin/users_spec` (36), `admin/permission_roles_localization_spec` (11 — **4 failing**), `preferences_spec` (12), `permission_matrix_verification_spec` (95 — **3 failing**) | ✅ except localization / matrix |
| API / characterization / security | `api/v1/sessions_spec` (6), `characterization/authentication_spec` (15), `standard_contract/rate_limiting_spec` (7) | ✅ |

**Baseline failures affecting this domain (not caused by this audit):**
* `permission_role_translations_spec` (2) and `admin/permission_roles_localization_spec` (4): missing translation
  `admin.permission_roles.permissions.manage_bank_disputes` (en and ar), which renders "translation missing" on the
  role form.
* `permission_matrix_verification_spec` (3): payroll-dashboard exposure checks (payroll-overview / alerts visible to
  a records-only user) — Attendance & Payroll concern surfaced through the permission matrix.

**Missing coverage (no request/integration spec found):**
* `admin/user_passwords` (admin reset) — none; would have caught OA-S4.
* `profile/passwords` (self change) — none.
* `admin/users#transfer_ownership` — none.
* `admin/users#update` negative cases: self role change, role change without `manage_roles`, foreign role id, owner `active=false` — none (OA-S1…S5).
* `admin/users#destroy` of the owner — none.
* `admin/permission_roles` functional CRUD / `assign_user` / `remove_user` request specs — only localization and matrix touch these routes; behaviour covered at policy level only.
* Web registration (`POST /users`) and web login request specs — service spec only; claim-verification (OA-S6) untested.
* Branch manager business validation (OA-S7) — none.
* Characterization coverage exists for the API session endpoints; **none** for the web account-administration flows.

## 10. Migration candidates

Target layout per the architecture document (final structure still to be chosen, e.g. `app/domains/organization_access/`
or `packs/organization_access/`). **Nothing is created now.**

| Category | Components |
|---|---|
| **SAFE TO MIGRATE** (after security fixes land) | `PermissionRole` + `PermissionRolePolicy` + `admin/permission_roles` controller/views; `UserAuditLog`; `Approvals::SelfApproval` (public interface); `BranchPolicy`; `admin/settings` controller/view (storage only); `preferences` / `locale` controllers; `Users::SessionsController` (auth infrastructure); `BusinessDay` → shared kernel |
| **NEEDS REFACTORING FIRST** | `User` (split account vs employee stewardship; remove WF/IP/FS helpers; replace `dependent: :destroy` cascades with deactivation); `Branch` (manager business validation; cascade destroys; `pos_terminals` nested write; laundry scope); `Business` (inverse associations; per-domain settings accessor); `EmployeeScope` / `BranchScope` (membership contract; business-filter manager ids); `UserPolicy` (owner/privilege guards; scope-aware); `admin/user_passwords`; registration flow (possession verification — product decision); `Api::V1::SessionsController` payload (compose WF/AP data) |
| **SHOULD REMAIN LEGACY TEMPORARILY** | `admin/users` (mixed WF/OA/IP form — migrate with Workforce); `admin/branches#show` (cross-domain dashboard → Reporting); `Admin::BaseController` gate and `WorkspaceHelper` (infrastructure, depend on the future permission registry); Devise views; declared-but-unimplemented `/api/v1/{businesses,branches,users}` |

Proposed (not created) domain building blocks:

| Kind | Proposal |
|---|---|
| Domain models | `Business`, `Branch`, `User` (account concern), `PermissionRole`, `UserAuditLog` |
| Domain services | Account lifecycle (`create_account_for`, `enable_login` with verification, `deactivate`, `reactivate`, `assign_role` with manage_roles + owner guards, `reset_password` with privilege guard, `transfer_ownership`); branch management (with manager validation); settings access |
| Domain policies | `BranchPolicy`, `PermissionRolePolicy`, account policy (split from `UserPolicy`) |
| Domain queries | `visible_employee_ids(user, permission)`, `visible_branch_ids(user, permission)`, `branches_for(business)`, `accounts_for(business)` |
| Domain interfaces | `Access.can?`, `Access.scope_for`, `Access.self_approval_allowed?`, `Accounts.*`, `Branches.*`, `Settings.settings_for(business, domain)`; **contract** `MembershipProvider` (implemented by Workforce) |

## 11. Migration risks

| Risk | Level | Why |
|---|---|---|
| Unfixed account-level vulnerabilities (OA-S1…S6) | **HIGH** | Moving vulnerable code would carry the holes into the new structure and complicate the fix; they are actively exploitable by low-privilege users and anonymous visitors |
| User ↔ Employee coupling (one model, one table, one admin form) | **HIGH** | Every domain references `users`; the admin form writes account + employee + inventory data together |
| Cascade deletes from `User` / `Branch` into WF/AP/IP data | **HIGH** | Violates the audit-first rule; any migration that touches associations can change deletion behaviour |
| Authorization coupling to Workforce (`EmployeeScope` / `BranchScope` → `ShiftAssignment`) | **HIGH** | Membership changes alter visibility for all 69 policies |
| Central permission catalogue & admin gate | MEDIUM | Every domain's permissions live in OA; changing their registration can silently change access |
| Business settings stored on `businesses` for other domains | MEDIUM | Settings screen and accessors must keep working while ownership of meaning moves |
| `admin/branches#show` cross-domain dashboard | MEDIUM | Reads AP/WF data from an OA controller |
| API login payload mixes WF/AP data | MEDIUM | First API clients (React/React Native) depend on this payload |
| Thin request coverage for account administration | MEDIUM | Regressions in password/role/owner flows would go unnoticed |
| Baseline translation failures on role screens | LOW | Pre-existing; noise during migration |
| Web login/registration throttling absent | LOW | Security hygiene; independent of migration |
| Legacy `notifications` / `notification_preferences` | LOW | Unused; no migration impact |

## 12. Proposed migration sequence (not implemented)

The application stays fully functional after every step; each step is a small, reviewed change set.

| Step | Action | Notes |
|---|---|---|
| 0 | **Security fixes (separate, approved task):** OA-S1…S6 (+ S7, S8) with regression specs, following the security-hardening pattern | Prerequisite; product decision needed for OA-S6 (verification method) |
| 1 | **Characterization coverage** for account administration: web login/registration, password change/reset, role assign/remove, toggle/transfer ownership, branch manager assignment, settings; plus API session payload | Locks behaviour before moves |
| 2 | **Extract interfaces** (still in place, no moves): `Access`, `Accounts`, `Branches`, `Settings` facades over existing code; define the `MembershipProvider` contract, backed by `BranchMembership` | Callers can start using facades incrementally |
| 3 | **Isolate ownership:** document/enforce `users` column stewardship; route account-field writes from `admin/users` through `Accounts`; stop cascade-delete intent for users/branches (deactivation) — each as its own approved behaviour change | Some items change behaviour → separate approval |
| 4 | **Introduce the domain namespace/structure** (tooling in report-only mode) | No behaviour change |
| 5 | **Move low-risk components:** `PermissionRole` (+ policy, controller, views), `UserAuditLog`, `SelfApproval`, `BranchPolicy`, settings/locale/preferences; `BusinessDay` → shared kernel | Mechanical moves; constants unchanged |
| 6 | **Migrate APIs incrementally:** logout (GREEN) then login (YELLOW, payload via WF/AP interfaces); keep cookie auth | Standard contract only with characterization proof |
| 7 | **Migrate controllers:** branches CRUD (after manager validation), user passwords, registration (after OA-S6) | `admin/branches#show` → Reporting later |
| 8 | **Remove legacy coupling:** `User` helpers for WF/IP/FS, `Business` inverse associations, permission catalogue → per-domain registration, admin gate from registry | Coordinated with Workforce migration |
| 9 | **Enforce dependency rules** for Organization & Access (no references to other domains except through contracts) | Turn on enforcement for this domain |

## 13. Open questions

1. **Account claim (OA-S6):** keep self-registration by email/phone? If yes, which proof of possession — SMS/WhatsApp OTP, emailed invite link, or admin-issued one-time code? Should inactive accounts be claimable at all?
2. **Who may assign roles?** Only `manage_roles` holders (current `PermissionRolesController` rule), or also `manage_employees` via the employee form? Recommended: `manage_roles` only, never self, never the owner.
3. **Privilege ordering:** may a `manage_roles` user grant permissions they do not hold themselves (today yes — `manage_roles` is effectively full admin)? Should that be restricted?
4. **Owner protection:** confirm that only the owner may reset the owner's password, and that the owner can never be deactivated or deleted by others.
5. **User deletion:** should `admin/users#destroy` exist at all given cascades into payroll/attendance? (Deactivation already exists.)
6. **Branch deletion:** should branches with attendance/payroll history be deletable, or only deactivatable?
7. **Configured scope for employee administration:** should a branch-scoped `manage_employees` holder be limited to employees in their scope (OA-S8)?
8. **Web throttling:** add rate limits to web login/registration mirroring the API login limits?
9. **Final structure name:** `app/domains/organization_access/` vs `packs/organization_access/` (Packwerk) — needed before step 4.

## 14. Final recommendation

Do **not** start moving Organization & Access code yet. First run a focused **Organization & Access security-hardening
task** (OA-S1 to OA-S6, plus S7/S8 if approved) with regression specs, answering open questions 1–4 beforehand. Then
add characterization coverage for account administration (step 1) and extract the in-place interfaces (step 2).
After that, the low-coupling components in §10 can be migrated mechanically; `User`, `admin/users` and
`admin/branches#show` follow once the Workforce boundary (Employee stewardship, membership contract) is in place.

---

## Migration Readiness

| | |
|---|---|
| **Ready areas** | `PermissionRole` (+ policy, controller, views), `UserAuditLog`, `Approvals::SelfApproval`, `BranchPolicy`, settings/locale/preferences controllers, web session controller, `BusinessDay` (→ shared kernel), API logout — all after the security fixes land |
| **Blocked areas** | `User` model and `admin/users` (User ≠ Employee split, cascade deletes, security findings); `EmployeeScope`/`BranchScope` (depend on Workforce membership); `admin/branches#show` (cross-domain dashboard); API login payload (WF/AP data); registration flow (OA-S6 decision) |
| **Refactoring required** | Membership contract; account-field writes out of the employee form; owner/privilege guards in `UserPolicy`; same-business validation for `permission_role` and branch managers; replace `dependent: :destroy` cascades from `User`/`Branch`; per-domain settings accessor; permission-group registration |
| **Security concerns** | **Critical:** OA-S1 self privilege escalation, OA-S2 cross-business role assignment. **High:** OA-S3 role assignment without `manage_roles`, OA-S4 owner password takeover, OA-S5 owner deactivation/deletion, OA-S6 unauthenticated account claim + enumeration. **Medium:** OA-S7 cross-business branch manager, OA-S8 scope-less employee administration. **Low:** OA-S9 web throttling, OA-S10 password floor / origin check |
| **Recommended first implementation step** | A separately approved **Organization & Access security-hardening task** fixing OA-S1 … OA-S6 with regression specs (same pattern as the API security hardening), preceded by decisions on open questions 1–4 |

---

## Security Hardening Status

Focused hardening of OA-S1 … OA-S6 (plus the requested server-side branch-manager scope, OA-S7). No schema change,
no migration, no file moves, no User/Employee redesign. Regression specs:
`spec/requests/security/organization_access_security_spec.rb` (43 examples) and the rewritten
`spec/services/users/registration_service_spec.rb` (18 examples). Against the pre-fix code, 26 of the 43 request
examples fail (every attack case); the remaining 17 lock in behaviour that must keep working.

| ID | Status | Fix (server-side) |
|---|---|---|
| OA-S1 self privilege escalation | **Fixed** | `UserPolicy#permitted_attributes` separates self-service profile fields from employment, account-status/access and role fields; `Admin::UsersController` permits only that list (web form hides the rest). A user editing their own record can change profile fields only |
| OA-S2 cross-business role | **Fixed** | `User` validates that `permission_role` belongs to the user's business (every write path); role ids are resolved through `current_user.business` in `admin/users` |
| OA-S3 role assignment / escalation | **Fixed** | Role changes require `manage_roles` and pass `PermissionGrants.can_change_role?` (never self, never the owner, only roles whose permissions the actor holds — old and new role). Role create/update may not add permissions the actor lacks (checked after `role_type` defaults); roles above the actor cannot be edited, deleted or assigned (`PermissionRolePolicy`). The owner is exempt |
| OA-S4 owner password takeover | **Fixed** | `UserPolicy#reset_password?` refuses the owner for anyone but the owner |
| OA-S5 owner lockout / deletion | **Fixed** | `destroy?` / `toggle_active?` refuse the owner; `active`, role and login identifiers (email/phone) of the owner are not editable by others; ownership transfer (owner-only) unchanged |
| OA-S6 account claim + enumeration | **Fixed** | Claiming a pending account requires an administrator-issued, signed invitation link (`User.generates_token_for(:account_claim)`, 7-day expiry, single use, invalid once deactivated; token carries no secrets) **and** the matching phone/email. All failures return one generic message. Employee managers see the link on pending employees (`UserPolicy#invite?`) |
| OA-S7 cross-business branch manager | **Fixed** | `Branch` validates that branch/area managers belong to the branch's business |

**Behaviour changes to note:**

* Pending employees can no longer activate with phone/email alone. An administrator shares the invitation link from
  the employee page. There is no automatic delivery: no SMS, WhatsApp or email infrastructure exists.
* Non-owners editing their own record in the admin area can change profile fields only. A non-owner can no longer
  deactivate themselves.
* `manage_roles` holders can no longer edit, delete or assign roles that include permissions they do not hold.
* Messages are unchanged for existing flows. The owner-deactivation message is kept, and new messages are localized
  in en and ar.

**Remaining security concerns (not in this task's scope):**

* **OA-S8** — a branch-scoped `manage_employees` holder can still edit any employee of the business (scope not applied).
* **New observation** — `manage_employees` can still reset the password of, or deactivate, *non-owner* users who hold
  more privileges (e.g. a `manage_roles` administrator). Only the owner is protected by this task.
* Data-scope escalation — role editing checks permissions, not the breadth of each permission's configured scope.
* OA-S9 (no throttling on web login/registration) and OA-S10 (password floor, origin check) are unchanged.
* There is no API endpoint that mutates Organization & Access data today. The model validations (roles, branch
  managers) and policies apply to any future API automatically.

---

## Remaining Security / Authorization Concerns

**Permission scope is not modelled as a first-class part of authority.** A narrow guard now prevents granting a
permission at a scope broader than the actor's own (see "Final Status — Profile Visibility and Role Scope" below).
It compares the existing scope strings only. It does not model *which* branches or areas a grant resolves to, and it
ranks a blank (hierarchy-default) scope as `area`.

**Permission scope must eventually be modeled as permission + scope + business + branch.**

The current model stores a permission list plus a per-permission scope string on `PermissionRole`, and resolves
target membership separately (`EmployeeScope`, `BranchScope`, shift assignments). The future Organization & Access
permission model should make each grant an explicit combination of:

| Dimension | Meaning | Example |
|---|---|---|
| **Permission** | the action | `manage_employees` |
| **Scope** | breadth of authority | self · branch · area · business |
| **Resource / business** | the tenant the grant applies to | Business A |
| **Branch** | the concrete branches a branch/area scope resolves to | Branch A, Branch C |

With that model, `manage_employees + business scope` is a strictly higher grant than
`manage_employees + branch scope`. "May only grant what you hold" can then compare scope breadth as well as
permission names. **Not implemented in this phase:** that larger model is future architecture work. The current guard
introduces no new security hole, and the existing business/branch scope checks are preserved.

Other open items (outside Organization & Access or deferred):

* `admin/salary_profiles` (`manage_salary_profiles`) and `admin/employee_insurance_profiles`
  (`manage_employee_insurance`) load employees business-wide and authorize by permission only. These are Attendance &
  Payroll and Workforce screens, outside this pass.
* ~~`UserPolicy#show?` lets any `view_employees` holder open any profile by URL~~ — **fixed** (see the final status
  below).
* The administrative-permission set used for the privilege hierarchy (`PermissionGrants::ADMINISTRATIVE_PERMISSIONS`
  = `manage_roles`, `manage_employees`, `manage_settings`, `manage_branches`) is a deliberate minimum. Operational
  privileges (payroll, finance) are not ranked. The future permission model should formalize privilege levels.
* OA-S9 (no throttling on web login/registration) and OA-S10 (password floor, origin check) are unchanged.

## Final Security Hardening Status

| ID | Status | Enforcement (server-side) |
|---|---|---|
| OA-S1 self privilege escalation | **Fixed** | `UserPolicy#permitted_attributes`; own record = profile fields only |
| OA-S2 cross-business role | **Fixed** | `User` validation + business-scoped role lookup |
| OA-S3 role assignment / permission escalation | **Fixed** | `manage_roles` required; `PermissionGrants` (no granting or managing above own permissions; role-type defaults checked) |
| OA-S4 owner password takeover | **Fixed** | Owner covered only by the owner (`PermissionGrants.covers?`) |
| OA-S5 owner lockout / deletion | **Fixed** | Same rule for deactivate / delete / login identifiers / role |
| OA-S6 account claim + enumeration | **Fixed** | Signed, expiring, single-use invitation link + matching phone/email; one generic error |
| OA-S7 cross-business branch manager | **Fixed** | `Branch` validation |
| OA-S8 scope-less employee management | **Fixed** | `UserPolicy#update?`, `reset_password?`, `toggle_active?`, `destroy?`, `invite?` and account/role/login fields require the target to be inside the actor's employee-management scope (`EmployeeScope#for_permissions(:manage_employees, :view_employees)`; business-wide only when explicitly configured; otherwise the branches/areas the actor manages) |
| Privilege hierarchy | **Fixed** | Taking control of an account (reset password, deactivate, delete, invitation, login identifiers, warehouse access, role) requires the actor's administrative permissions to cover the target's (`PermissionGrants.covers?`). Profile data of an in-scope, higher-privileged user stays editable |

**Final authorization decision** for another user's account:
actor → permission (`manage_employees`, and `manage_roles` for roles) → same business (scoped lookup, 404 otherwise)
→ employee-management scope (branch/area/business) → target's administrative authority ⊆ actor's → owner protected.

**Behaviour changes from OA-S8:**

* A `manage_employees` holder without a configured scope, and without branches or areas they manage, can no longer
  manage other employees by URL. This matches the employee list, which already hid those employees from them.
  Business-wide management needs an explicit `business` scope on `manage_employees` or `view_employees`.
* An employee assigned to several branches can be managed by the manager of any of those branches.
* Newly created employees with no shift assignment can only be managed by business-wide managers (and the owner)
  until they are assigned.

**Tests**

| Suite | Result |
|---|---|
| OA security specs (`organization_access_security_spec` 43, `organization_access_scope_hierarchy_spec` 23, `registration_service_spec` 18) | 84 examples, 0 failures |
| API security specs | 24 examples, 0 failures |
| Web security specs (all of `spec/requests/security`) | 106 examples, 0 failures |
| API characterization / contract | 173 examples, 0 failures, 1 pending (D1, pre-existing) |
| Existing OA specs (admin users, user/permission-role policies, scopes, user/branch models) | 211 examples, 0 failures |
| Full suite | 6,901 examples, 87 failures, 1 pending — **all pre-existing** (no failure in any file touched by the security work). The mix differs from earlier runs only in date-dependent specs (the date rolled over to 2026-10-01): `payroll/auto_generator` now passes; `salary/advance_eligibility_calculator` (+2) and `models/employee_request` (+1) now fail. All 5 newly failing examples also fail with every change of this phase stashed |

Against the previous pass's `UserPolicy`, 14 of the 23 new scope/hierarchy examples fail: every attack case. The 9
allowed-behaviour examples pass on both versions.

**Database / schema:** no changes; no migrations.

## Final Status — Profile Visibility and Role Scope

| Item | Status | Enforcement (server-side) |
|---|---|---|
| Employee profile view scope (IDOR by URL) | **Fixed** | `UserPolicy#show?` = own record, or `view_employees` **and** the target is in the same scope as the employee list (`UserPolicy::Scope`: configured `view_employees` scope, else the management hierarchy), or in the actor's employee-management scope. Another business → 404 (business-scoped lookup); out of scope inside the business → the app's standard "not authorized" redirect, with no profile data rendered |
| Role permission scope escalation | **Fixed (narrow guard)** | `PermissionGrants.overbroad_scopes`: for every scopable permission in a role, the role's scope must not be broader than the actor's own scope for that permission (`self < branch < area < business`; blank = hierarchy default, ranked `area`). Enforced through `manageable_role?`, so it applies to role create, role edit (including permission or scope changes), role delete, and role assignment from the role screen and the employee form. The owner is exempt |

**Cases verified:** profile view — same branch ✔, other branch ✘, business-wide ✔, other business ✘ (404), multi-branch
✔. Role scope — branch admin grants branch ✔, branch admin grants business ✘ (create / widen / blank default / edit or
delete a broader role / assign a broader role), business admin grants business ✔, cross-business role ✘ (404),
owner ✔.

**Behaviour changes:**

* A branch-scoped role administrator must set an explicit `branch` (or `self`) scope on the scopable permissions they
  grant. A blank scope means the hierarchy default and is ranked `area`.
* Profiles outside the viewer's scope can no longer be opened by URL. The employee-data-request page already links to
  a profile only when `show?` allows it.

**Tests**

| Suite | Result |
|---|---|
| OA security specs (security 43 + scope/hierarchy 23 + visibility/role-scope 17 + registration 18) | 101 examples, 0 failures |
| API security specs | 24 examples, 0 failures |
| Web security specs (all of `spec/requests/security`) | 123 examples, 0 failures |
| Existing scope/policy specs (all policies, scopes, self-approval, admin users/branches, user/branch/role models) | 942 examples, 5 failures — all pre-existing (expense 1, operations dashboard 3, payroll period 1); they fail identically with every change of this phase stashed |
| API characterization / contract | 173 examples, 0 failures, 1 pending (D1, pre-existing) |
| Full suite | 6,918 examples, 87 failures, 1 pending — identical failing files and counts to the previous security pass; all pre-existing, none in files touched by the security work |

With only this task's two rules reverted, 6 of the 17 new examples fail: every attack case. One existing example
(`user_policy_spec`: "permits branch_manager … — scope handles branch isolation") asserted the old out-of-scope
visibility and was updated to expect denial.

**Database / schema:** no changes; no migrations.

**Still documented as follow-up (not fixed here):** salary-profile and insurance-profile business-wide access
(other domains); the full permission + scope + business + branch model; OA-S9 (throttling) and OA-S10 (password
policy, origin check); the administrative-permission set used by the privilege hierarchy is a minimum.

## Characterization Status

Detailed in `organization-access-characterization.md`. Tests and documentation only; production code, schema and
migrations are unchanged.

* **New suite:** `spec/characterization/organization_access/` has 5 files and 69 examples, all passing (also in
  random order). Areas covered:
  * web session and authentication
  * account self-service and admin account management
  * permission-role administration
  * branches, settings and locale
  * cross-domain access contracts
* **Security contracts:** covered by the existing `spec/requests/security/organization_access_*` specs (83
  examples) and `registration_service_spec`. Not duplicated.
* **Full suite:** 6987 examples, 87 failures, 1 pending. All 87 are **pre-existing baseline** failures: the same
  files and counts as before this phase. **New failures: 0.**
* **Known defects characterized (not fixed):**
  * OA-D1: user destroy reports success when blocked
  * OA-D2: branch destroy reports success when blocked
  * OA-D3: accountant role-type defaults are invalid
  * OA-D4: no audit for role, status, branch and settings changes
* **Readiness:**
  * **SAFE TO START** for the low-coupling components (`PermissionRole`, `UserAuditLog`, `SelfApproval`,
    `BranchPolicy`, `Branch` CRUD, settings, locale, sessions, `BusinessDay`).
  * **PARTIALLY COVERED** for `User`, `admin/users` and the access scopes. These depend on the Workforce boundary.
  * **NOT SAFE YET** to restructure the admin-area permission gate and navigation.

## PermissionRole Pilot

`PermissionRole` is the first Organization & Access component chosen for migration. The read-only plan is in
`permission-role-migration-plan.md`. Nothing in it is implemented.

* **Approach:** introduce an Organization & Access boundary under `app/services/organization_access/`, following
  the repo's existing `Finance::` / `Inventory::` / `Shifts::` service namespaces. Route reads and writes through
  it, then remove legacy access. The plan has 7 steps, each revertible and each leaving the application working.
* **Kept stable:**
  * the `PermissionRole` constant and table (15 data migrations and about 150 specs depend on it)
  * `User#can?` / `#scope_for` as the cross-domain authorization interface (about 570 call sites, unchanged)
  * routes, web flows, and the API login payload (`permissions`)
* **Database:** no schema change required.
* **Cross-domain edits:** only two, both read-only catalogue lookups: Laundry `PERMISSION_GROUPS` and the
  onboarding policy. User ≠ Employee is not touched.
* **Before implementation:** add the 6 REQUIRED tests listed in the plan's "Step 1 — Characterization Gaps":
  * `PermissionGrants` unit decision table
  * API login permissions for a role holder and for the owner
  * Laundry and onboarding permission-group membership pins, plus a positive onboarding `index?`
  * `User#can?` with String vs Symbol arguments

  Also record the baseline failing example IDs. Everything else is already covered.
* **Locked decisions:**
  * no new role-change audit records (D1)
  * OA-D3 not fixed in the pilot (D2)
  * R-L4 out of scope (D3)
  * `PermissionRole` / `permission_roles` unchanged, with no migration (D4)
* **New defect found:** `lib/tasks/attendance.rake` queries a non-existent `permission_roles.role` column (R-L4).
* **Physical move and migration verification (Steps 7A/7B):**
  * `PermissionRole` now lives in `app/models/organization_access/permission_role.rb` (collapsed directory). The
    model name (`PermissionRole`) and table (`permission_roles`) are unchanged, and **no database migration is
    required** for `PermissionRole`.
  * Of the **15** historical migrations that reference `PermissionRole` (previously miscounted as 16), **14 passed
    down/up** in a disposable database.
  * The remaining one (`20260730140000_rename_pos_domain_to_sales`) fails before its `PermissionRole` code, because
    of the unrelated, pre-existing POS/Sales schema drift.
  * **Step 7A caused no migration compatibility issue.** Details are in the plan's "Step 7B — Fresh Migration
    Verification Status".
