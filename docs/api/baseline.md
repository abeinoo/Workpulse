# API Baseline — `/api/v1` before the API-foundation phase

**Captured:** 2026-09-30 on `main` @ `c5de449` (branch `feature/api-foundation`).
**Purpose:** record the existing API contract *before* any foundation change,
so later changes can be proven backward compatible. Locked by
`spec/requests/api/v1/characterization/`.

## 1. Test baseline (before any change)

Run on a clean checkout of `main` @ `c5de449` (isolated git worktree).

| Suite | Examples | Failures | Pending |
|---|---|---|---|
| Existing API specs (`spec/requests/api`) | 119 | 33 | 0 |
| Full suite (`bundle exec rspec`, 15 min) | 6,600 | 96 | 0 |

Warnings: 62, all the same Rack deprecation
(`Status code :unprocessable_entity is deprecated … use :unprocessable_content`)
raised by `have_http_status(:unprocessable_entity)` in existing specs.

After the characterization suite was added (still on unchanged code): the
characterization suite itself is **88 examples, 0 failures, 3 pending** (the
pending examples are the known defects S1, S2, D1 below).

## 2. Endpoints

Legend — **Auth**: `S` = Devise session cookie, `D` = device token, `–` = none.
**Authz**: how access is decided today. All collections are **unpaginated**.
Unless noted, success = `{success: true, data}`, error = `{success: false, message, errors}`.

| Method & path | Auth | Authz (today) | Success | Notable errors |
|---|---|---|---|---|
| `POST /api/v1/auth/login` | – | credentials; inactive users rejected | 200 user payload (+ session cookie) | 401 `Invalid credentials`; 400 missing params (Rails) |
| `DELETE /api/v1/auth/logout` | S | signed in | 200 `{message}` | 401 Devise |
| `POST /api/v1/attendance/check_in` | S | self; `allow_mobile_attendance`; branch must be a current assignment | 201 attendance | 403 not allowed; 404 `Branch not found`; 422 rule |
| `POST /api/v1/attendance/check_out` | S | self; branch must belong to business | 200 attendance | 403; 404; 422 |
| `GET /api/v1/attendance/today` | S | self | 200 attendance or `null` | 401 |
| `POST /api/v1/attendance/punch` | D | device's business; employee by `employee_code` then id within that business | 200 punch payload | 401 token; 404 employee; 422 timestamp / rule |
| `GET /api/v1/attendance_records` | S | `AttendanceRecordPolicy::Scope` | 200 array (current business month by default) | bad dates silently fall back |
| `GET /api/v1/attendance_records/:id` | S | scope + `show?` | 200 record + adjustments | 403 / 404 |
| `PATCH /api/v1/attendance_records/:id` | S | scope + `manage_attendance` | 200 | 403 / 404 / 422 |
| `GET /api/v1/employee_requests` | S | `EmployeeRequestPolicy::Scope` | 200 array | – |
| `POST /api/v1/employee_requests` | S | created for `current_user` | 201 | 422 `Failed to submit request` + full messages |
| `GET /api/v1/employee_requests/:id` | S | scope + `show?` | 200 | 404 |
| `PATCH /api/v1/employee_requests/:id/{approve,reject,cancel}` | S | scope + policy (no self-approval) | 200 | 403 / 404 / 422 |
| `GET /api/v1/advances` (standard contract since this phase) | S | `AdvancePolicy::Scope` | 200 array | – |
| `GET /api/v1/advances/:id` (standard contract since this phase) | S | scope + `show?` | 200 | 404 |
| `GET /api/v1/shifts` | S | business scope only — **no `authorize`** (any employee) | 200 array | – |
| `POST /api/v1/shifts` | S | `manage_shifts` | 201 | 403; 422 `Failed to create shift` |
| `GET/PATCH/PUT/DELETE /api/v1/shifts/:id` | S | business + policy | 200 (show adds raw `penalty_rules`) | 403 / 404 / 422 |
| `GET/POST /api/v1/shifts/:shift_id/penalty_rules`, `PATCH/PUT/DELETE …/:id` | S | shift `show?` / `update?` | 200 / 201 — **raw model attributes** | 403 / 404 / 422 |
| `GET /api/v1/shift_assignments`, `GET …/:id` | S | `ShiftAssignmentPolicy::Scope` | 200 | 404 |
| `POST /api/v1/shift_assignments` | S | `assign_shifts` (class-level) | 201 | 403; 422 `Branch or shift not found in this business` — **see S1** |
| `PATCH/PUT/DELETE /api/v1/shift_assignments/:id` | S | scope + policy | 200 | 403 / 404 / 422 |
| `GET/POST /api/v1/users/:user_id/salary_profiles`, `GET/PATCH/PUT …/:id` | S | `policy_scope(User)` + `SalaryProfilePolicy` | 200 / 201 | 403 / 404 / 422 |
| `GET/POST /api/v1/payroll_periods`, `GET/DELETE …/:id` | S | status-gated `PayrollPeriodPolicy::Scope` | 200 / 201 (`entry_count` only for `view_payroll_analytics`) | 403 / 404 / 422 (create/destroy render raw exception messages) |
| `PATCH /api/v1/payroll_periods/:id/{submit_for_review,approve_all_pending,finalize,mark_paid,regenerate,reopen,complete_branch_review}` | S | per-transition permission | 200 period | 403 / 404 / 422 |
| `GET /api/v1/payroll_periods/:pid/payroll_entries`, `GET/PATCH/PUT …/:id` | S | `PayrollEntryPolicy::Scope` | 200 (show adds line items + attendance) | 404; 422 paid period |
| `GET/POST /api/v1/payroll_periods/:pid/payroll_adjustments`, `DELETE …/:id` | S | scope + policy | 200 / 201 | 403 / 404 / 422 |
| `PATCH /api/v1/payroll_line_items/:id/{approve,reject}` | S | scope + policy | 200 line item | 403 / 404 / 422 |
| `PATCH /api/v1/payroll_line_items/:id/waive` | S | — | **always 500 — see D1** | |
| `GET /api/v1/reports/payroll/summary` | S | `view_payroll_analytics` + period scope | 200 | **401** (not 403) without permission |
| `GET /api/v1/reports/payroll/export` | S | same | 200 `text/csv` | 401 |
| `GET /api/v1/reports/attendance` | S | `view_employees` or `manage_employees` | 200 | **401** (not 403); 422 bad date; 404 foreign branch — **see S2** |

### Response structures

* Legacy success: exactly `{ "success": true, "data": … }`.
* Legacy error: exactly `{ "success": false, "message": "…", "errors": [ … ] }`.
* Unauthenticated (JSON): `401 {"error": "You need to sign in or sign up before continuing."}` (Devise).
  Unauthenticated (non-JSON): `302` → `/users/sign_in`.
* Rails-level errors (e.g. `ParameterMissing`) are rendered by Rails, outside the envelope.
* Field sets per endpoint: see `openapi.yaml` and the characterization specs.

## 3. Cross-cutting behaviour (before this phase)

| Concern | Baseline |
|---|---|
| Authentication | Devise session cookie shared with the web app; device token for punches. No tokens. CSRF skipped. See `authentication.md`. |
| Authorization | Pundit policies + `policy_scope`; `EmployeeScope` / `BranchScope` inside the scopes. Not enforced mechanically (no `verify_authorized`). |
| Tenant isolation | Business derived from `current_user` / device; records loaded through scopes or `current_business.*`. Exceptions: S1, S2. |
| Pagination | None. Every index returns the full list; `page` / `per_page` are ignored. |
| Filtering | Ad hoc: `start_date`/`end_date` (attendance records — silent fallback on bad input; attendance report — 422), `payroll_period_id` (entries index), `branch_id` (attendance report). No sorting or search. |
| Serialization | Controller-private `*_json` hash builders; penalty rules render raw model attributes (`created_at`, `updated_at`, …). Decimals as strings. Attendance timestamps converted to the business timezone. |
| Errors | Only Pundit (403) and RecordNotFound (404) rescued; unexpected errors are Rails 500s. Validation errors are free-text arrays. Two failure statuses for "not permitted": 403 (Pundit) and 401 (`render_unauthorized` in report controllers). |
| Rate limiting | None. |
| CORS | None (no `Access-Control-*` headers). |
| Request tracing | `X-Request-Id` header + `request_id` log tag only. |
| Documentation | None. |

## 4. Known defects (documented, NOT fixed in this phase)

Each is locked by a `pending` spec that will start failing — prompting its
removal — once the defect is fixed.

| ID | Severity | Defect | Evidence | Spec |
|---|---|---|---|---|
| **S1** | **Critical (tenant isolation)** | `POST /api/v1/shift_assignments` takes `user_id` from params and validates it neither against the caller's business nor their employee scope. `Shifts::Assigner` checks only `branch_id` / `shift_id`; `ShiftAssignment` has no user-business validation. A manager with `assign_shifts` could assign a user of **another business** (or outside their branch scope) to their shift. | `app/services/shifts/assigner.rb` (`valid_business_scope?`), `app/controllers/api/v1/shift_assignments_controller.rb` | `characterization/management_spec.rb` |
| **S2** | **High (scope leak)** | `GET /api/v1/reports/attendance` without `branch_id` returns **business-wide** per-employee attendance (names included) to anyone holding `view_employees`/`manage_employees`, ignoring their branch/area scope. | `app/controllers/api/v1/reports/attendance_controller.rb` | `characterization/payroll_spec.rb` |
| **D1** | High (broken endpoint) | `PATCH /api/v1/payroll_line_items/:id/waive` always raises `NoMethodError` (HTTP 500): `PayrollLineItemPolicy#waive?` was renamed `waive_deduction?` in `d950781`; the API controller was not updated. | `app/controllers/api/v1/payroll_line_items_controller.rb:29` | `characterization/payroll_spec.rb`; also 17 failures in `payroll_waive_scope_spec.rb` |
| **D2** | Medium | Routes declared without implementations: `api/v1/businesses` (show/update), `api/v1/branches` (all), `api/v1/users` (all except nested salary profiles), `new`/`edit` for shifts and shift assignments, `PATCH api/v1/employee_requests/:id/pay`. | `config/routes.rb` | `spec/docs/openapi_spec.rb`, `characterization/management_spec.rb` |
| D3 | Medium | Permission failures in report controllers return **401** `Not authorized` instead of 403. | `Api::V1::BaseController#require_manager!`, `Reports::PayrollController` | characterization |
| D4 | Medium | `GET /api/v1/shifts` calls no `authorize` — every employee can list all business shifts. Low data sensitivity. | `shifts_controller.rb#index` | characterization |
| D5 | Medium | `AdvancePolicy::Scope` gives every `view_payroll` holder **all** advances in the business, ignoring the configured `view_payroll` data scope (branch managers see other branches' advances). Needs a product decision. | `app/policies/advance_policy.rb` | — |
| D6 | Low | `PayrollPeriodsController#create/#destroy` render raw exception messages (`rescue ArgumentError, RuntimeError` / `rescue StandardError`), which can expose internals. | `payroll_periods_controller.rb` | — |
| D7 | Low | Business logic in API controllers: `approve_all_pending` updates line items directly; `PayrollEntriesController#update` creates bonus line items with `to_f` money; `PayrollAdjustmentsController` writes `PayrollAuditLog` directly; `SalaryProfilesController#update` updates the profile directly. | respective controllers | — |
| D8 | Low | Penalty rules are serialized as raw model attributes (any future column is exposed automatically). | `penalty_rules_controller.rb`, `shifts_controller.rb#shift_json` | characterization |

## 5. Pre-existing failing specs (not caused by this phase)

All 96 failures exist on unchanged `main`. None is caused or fixed by this phase.

**API (33) — three root causes:**

| Spec file | Failures | Cause |
|---|---|---|
| `spec/requests/api/v1/payroll_waive_scope_spec.rb` | 17 | Real defect **D1** (waive endpoint raises). |
| `spec/requests/api/v1/payroll_visibility_spec.rb` | 9 | Stale spec: sets up an `under_review` period for managers holding only `view_payroll` + `view_payroll_analytics`, but the permission refactor (`3f336f7`) deliberately limits `under_review` periods to payroll-pipeline permission holders → 404 (the CSV parse errors are that JSON 404 body parsed as CSV). |
| `spec/requests/api/v1/attendance_spec.rb` | 7 | Date time-bomb in the spec: `effective_from: 1.month.ago` is evaluated at real time (2026-08-30) and the examples then `travel_to` 2026-05-25, before the assignment starts → 404 `Branch not found`. |

**Outside the API (63) — not investigated in this phase** (listed so they are
not mistaken for regressions):

| Spec file | Failures |
|---|---|
| `spec/services/payroll/auto_generator_spec.rb` | 11 |
| `spec/services/scheduling/template_applier_spec.rb` | 10 |
| `spec/services/inventory/stock_count_poster_spec.rb` | 6 |
| `spec/requests/admin/permission_roles_localization_spec.rb` | 4 |
| `spec/services/attendance/check_in_service_spec.rb` | 4 |
| `spec/requests/payroll_review_approval_paths_spec.rb` | 4 |
| `spec/requests/permission_matrix_verification_spec.rb` | 3 |
| `spec/policies/operations_dashboard_policy_spec.rb` | 3 |
| `spec/services/salary/advance_eligibility_calculator_spec.rb` | 2 |
| `spec/requests/sidebar_active_state_spec.rb` | 2 |
| `spec/requests/dashboard_spec.rb` | 2 |
| `spec/models/permission_role_translations_spec.rb` | 2 |
| 10 other files (1 each): `scheduling/conflict_detector`, `performance/reviews_analytics`, `inventory/products_barcode`, `inventory/barcode_labels`, `admin/shift_templates`, `adjustments`, `payroll_period_policy`, `expense_policy`, `shift_assignment` model, `attachment_helper` | 10 |
