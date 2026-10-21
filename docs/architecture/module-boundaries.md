# WorkPulse — Six-Domain Architecture (Module Boundaries)

**Status:** Target architecture, partially implemented (Milestone 1 as of `ae74dcc` on `feature/api-foundation`;
Milestone 2 on `feature/milestone-2-attendance-payroll`, see `next-pilot-selection.md` "Milestone 2").

* The six-domain model below remains the **target**.
* **API infrastructure exists:** `/api/v1` standard contract (errors, pagination, filtering, serialization, request
  tracing, login rate limiting); see `docs/api/`.
* **Organization & Access is partially migrated:** the `PermissionRole` pilot (`app/models/organization_access/`,
  `app/services/organization_access/`); see `permission-role-migration-plan.md`. Since Pilot 5 the access scopes read
  branch membership through `OrganizationAccess::MembershipProvider` (implemented by `Workforce::MembershipProvider`);
  see `next-pilot-selection.md` §20. Since Batch W (on `feature/pilot-12-pos-terminals`, not yet merged) the employee form applies warehouse access only through
  the OA contract `OrganizationAccess::UserWarehouseAccess` (implemented by IP, `Inventory::UserWarehouseAssignments`),
  and OA's inverse associations and the `WorkspaceHelper` navigation registry are classified and frozen by
  `spec/architecture/organization_access_outbound_boundary_spec.rb` (`next-pilot-selection.md` §28).
* **Workforce is partially migrated:** `Department`, `JobTitle`, the Performance evaluation group and
  `EmployeeInsuranceProfile` (Pilot 8, behind the `Employee::InsuranceProfileEffects` contract) are in
  `app/models/workforce/`; see `next-pilot-selection.md`. Since Pilot 9 the `EmployeeRequest` lifecycle reaches the
  payroll effect of late / early-leave permissions only through the WF contract `Requests::PermissionPayrollEffects`,
  and since Pilot 10 (M4, `feature/pilot-10-punch-correction`) the punch-correction attendance and payroll effects only
  through the WF contract `Requests::PunchCorrectionEffects`; the canceller's pre-M4 punch rollback was removed in Pilot 10
  M6 (`next-pilot-selection.md` §25.11). Since Batch A (on `feature/pilot-12-pos-terminals`, not yet merged) the
  salary-advance payment records the `Advance` only through the WF contract `Requests::AdvanceEffects`, implemented by
  AP (`Payroll::AdvanceEffects`); enforced by `spec/architecture/workforce_request_advance_boundary_spec.rb`
  (`next-pilot-selection.md` §30). Since Batch V (on `batch-v/request-validation-reads-2`, not yet merged) the
  request form, show page, validation and policy read Attendance & Payroll only through the WF read contract
  `Requests::RequestFormReads`, implemented by AP (`Payroll::RequestFormReads`); enforced by
  `spec/architecture/workforce_request_validation_reads_boundary_spec.rb` (`next-pilot-selection.md` §37). Since F2
  (on `migration/f2-shift-assignment-attendance`, not yet merged) the Shifts & Scheduling group asks whether attendance
  was recorded against a shift assignment only through the WF read contract `Shifts::AttendanceUsage`, implemented by
  AP (`Attendance::ShiftAssignmentUsage`); enforced by `spec/architecture/workforce_shift_scheduling_boundary_spec.rb`
  (`next-pilot-selection.md` §41). Since SAL (on `migration/sal-employee-salary-panel`, not yet merged) the employee
  page receives its salary card only through the WF UI-composition contract `Employee::ProfilePanels`, implemented by
  AP (`Payroll::EmployeeSalaryPanel`, which owns the card partial); enforced by
  `spec/architecture/workforce_employee_salary_panel_boundary_spec.rb` (`next-pilot-selection.md` §42).
* **Attendance & Payroll is partially migrated (Milestone 2):** the biometric punch channel, Employee Obligations and
  Penalty Rules (`app/models/attendance_payroll/`), with boundary specs; `Payroll::FinalizationEffects` (AP-defined
  contract) and `Attendance::ShiftPenaltyRules` (implementation of the WF `Shifts::PenaltyRuleSettings` contract);
  `Payroll::InsuranceProfileEffects` (Pilot 8), `Payroll::PermissionPayrollEffects` → `PermissionApplier` /
  `PermissionReverter` (Pilot 9) and `Attendance::PunchCorrectionEffects` → `Payroll::EntryRecalculator` (Pilot 10)
  implement WF contracts.
* **Finance & Sales is partially migrated (Milestone 2):** the Expenses group (`app/models/finance_sales/`), with a
  boundary spec; it implements `Payroll::FinalizationEffects` (`Finance::PayrollFinalizationEffects`). Since Pilot 12
  (on `feature/pilot-12-pos-terminals`, not yet merged) it also implements the OA contract
  `OrganizationAccess::BranchTerminalSettings` (`Finance::BranchPosTerminals`): the branch form stages POS terminal rows
  only through it (`spec/architecture/finance_sales_pos_terminal_boundary_spec.rb`; `next-pilot-selection.md` §27).
* **Inventory & Purchasing is partially migrated (Pilots 6 and 7):** `Supplier`, `Brand` and `ProductCategory` live
  in the collapsed `app/models/inventory_purchasing/` (top-level constants and tables unchanged), each with a boundary
  spec; see `next-pilot-selection.md` §21 and §22. Since Batch S (on `batch-s/goods-receipt-payments`, not yet merged;
  it now includes `main` with Batch V, PR #58, and the Pilot 12 close-out, PR #59)
  the goods-receipt services write the settlement and custody ledgers only through the IP contract
  `Inventory::GoodsReceiptPaymentEffects`, implemented by FS (`Finance::GoodsReceiptPaymentEffects`); enforced by
  `spec/architecture/inventory_finance_goods_receipt_payment_boundary_spec.rb` (`next-pilot-selection.md` §38).
  Since S2 (on `migration/s2-purchase-request-advances`, not yet merged) the Purchase Request advance deposits and
  reversals, and the advance's custody-account choice, go only through the IP contract
  `Inventory::PurchaseRequestAdvanceEffects`, implemented by FS (`Finance::PurchaseRequestAdvanceEffects`); the same
  boundary spec now allows **no** Inventory → Finance & Sales ledger write (`next-pilot-selection.md` §39).
* **Reporting is partially migrated (Pilot 11):** the laundry operating-cost report `Finance::Reports::LaundryCostSummary`
  (`app/services/finance/reports/`, moved from `Laundry::LaundryCostSummaryReport`), with a read-only boundary spec;
  see `next-pilot-selection.md` §26. Its controller stays under `/laundry/reports/cost_summary` as Reporting UI.
  Since Batch R (on `feature/pilot-12-pos-terminals`, not yet merged) the whole Reporting surface is enforced read-only by
  `spec/architecture/reporting_read_only_boundary_spec.rb`: no writes (the approved view-audit calls excepted, D-R2),
  nothing outside Reporting names a Reporting service, every file of the Reporting-adjacent service folders classified
  (single-domain Finance & Sales reports stay FS-owned in place, D-R1) — `next-pilot-selection.md` §28.
* The cross-domain violations recorded in §12.2 remain until their owning steps; those resolved in Milestone 2 are
  marked there and in §14.2.

**Original code baseline (for the analysis below):** branch `feature/api-foundation` @ `a4e9a96`.
**Decisions applied:** six top-level domains; ownership decisions 1–12 of the ownership-resolution review
(User vs Employee, supporting models, Payroll → Finance, Requests → Payroll/Attendance, Inventory → Finance,
Reporting, cross-domain write rule, scheduling eligibility, unresolved items, dependency graph, migration sequence).
**Out of scope:** Booking (extensibility note only, §21), React, React Native, any code, route, API or schema change.

---

## 1. Architecture Overview

WorkPulse is a single Rails 8.1 application on one PostgreSQL database, organised today by technical layer
(`app/models`, `app/services/<area>`, `app/controllers/<namespace>`, `app/policies`). Tenancy is row-level
(`business_id`); authorization is Pundit plus `EmployeeScope` / `BranchScope`; most business logic lives in services.

The target is a **modular monolith of six top-level business domains** inside the same Rails application and the same
database. Each domain owns its models, tables, business rules, services, policies, controllers and views; exposes a small
public interface; and interacts with other domains only through **explicit in-process public interfaces or domain
events**. There is **no HTTP between domains and no microservices**.

### Evidence base

Every statement is derived from the repository:

* **Code inventory:** 113 models, 130 tables, 125 controllers, 264 services, 69 policies, 3 jobs, 4 rake files, and
  all routes.
* **Read-only dependency scan:**
  * Every model is assigned to a domain, and every `app/` file to a domain by path.
  * References to other domains' model constants are counted. `belongs_to`, `has_many` and `has_one` declarations
    are scanned separately.
  * Figures appear as "N refs / M files". They measure coupling, not correctness.
* **Write-path review:** every place that creates or updates another domain's records.
* **Git history** for legacy tables and **tests/churn per domain** (§19).

## 2. Six-Domain Model

| # | Domain | Internal areas (not separate modules) | Abbrev. |
|---|---|---|---|
| 1 | **Organization & Access** | Business & settings storage, Branches, **User accounts**, Roles & Permissions, Access scopes, Segregation-of-duties rule | OA |
| 2 | **Workforce** | **Employees** (profile, employment information), Onboarding (employee data requests), Insurance profile, Departments & job titles, Branch assignments & Scheduling (shifts, assignments, templates, rule profiles), Scheduling eligibility, Employee Requests, Performance | WF |
| 3 | **Attendance & Payroll** | Attendance (punches, devices, records, adjustments, calculations, penalty rules, geofencing), Payroll (salary profiles, periods, entries, items, bonuses/commissions/deductions, advances, obligations, finalization) | AP |
| 4 | **Inventory & Purchasing** | Inventory (warehouses & warehouse access, products, barcodes, stock ledger/movements, issue vouchers, transfers, adjustments, counts), Purchasing (suppliers, purchase requests, receiving/goods receipts), Laundry (towels, batches, consumption, cost rates) | IP |
| 5 | **Finance & Sales** | Expenses, Custody & balance requests, Financial settlements, Payment methods, Cash Management (daily reconciliation, till custody, deposits, refunds, remaining balances, financial adjustments), Bank reconciliation & disputes, Sales Import (POS sales and card-acquirer files) | FS |
| 6 | **Reporting** | Cross-domain dashboards, reports, analytics, aggregations — **owns no business data** | RP |

Plus two non-domain layers: a minimal **Shared Kernel** (§15) and **Infrastructure** (§16).

**Report placement rule:** a report that reads only one domain stays in that domain (inventory, laundry, performance,
payroll, expense/custody reports). Reporting owns only cross-domain aggregations.

## 3. Users vs Employees

### 3.1 Concepts

| | **User** (Organization & Access) | **Employee** (Workforce) |
|---|---|---|
| Represents | Access and authentication | Workforce membership and employment |
| Responsible for | Authentication, login credentials (email/phone as login identifiers, password), account status (`active`), role (`permission_role`), permissions, access scopes, business membership (`business_id`), locale | Employee profile, employment information (employee code, hire date, employment type), department, job title, identity & emergency data, branch assignments, onboarding/employment lifecycle, scheduling eligibility, employee requests, performance |
| Exists without the other? | **Yes** — e.g. the owner or an administrator who is not part of the scheduled workforce | **Yes** — an employee who never logs in |

**User ≠ Employee.** Some users are not employees; some employees have no user account. Workforce may *associate*
an Employee with a User account, but Workforce **must not own or directly modify** User authentication/authorization
data (credentials, account status, role, permissions, scopes).

```
Organization & Access
  User  (account: credentials, status, role, permissions, scopes, business membership)
    ↓  0..1 association
  Employee  (Workforce: profile, employment, department, job title, assignments, requests, performance)
```

### 3.2 How this maps to the current code (no change proposed)

There is **no separate `Employee` model or table today.** Both concepts live in the single `User` model /
`users` table (137 foreign keys point at it). The separation is therefore documented as **column stewardship** on
the shared table until a future, separately approved change:

| `users` columns | Steward | Why |
|---|---|---|
| `email`, `phone_number` (login identifiers), `encrypted_password`, `reset_password_*`, `remember_created_at`, `active`, `permission_role_id`, `business_id`, `preferred_locale` | **OA** (User) | Authentication, account status, role, membership (`User.find_for_database_authentication`, `active_for_authentication?`, `User#can?`) |
| `first_name`, `last_name`, `employee_code`, `job_title`, `department`/`department_id`, `hire_date`, `date_of_birth`, `address`, `employment_type`, `identity_card_number`, `identity_card_expiry_date`, `emergency_contact_*`, `admin_notes`, attachments (`profile_photo`, `avatar`, `id_card`, `national_id_front/back`) | **WF** (Employee) | Employee profile and employment information (`EmployeeDataRequests::EmployeeAttributes`, `User#assign_employee_code`, `job_title_from_catalog`) |
| `allow_mobile_attendance`, `allow_biometric_attendance` | **AP** | Attendance-channel eligibility read by `Api::V1::AttendanceController` and `Attendance::PunchService` |
| `notification_preferences` | Unused (legacy of the removed notification system) | No code reads it |

Evidence that "Employee without User account" already occurs: onboarding approval creates the employee with
`User.new(EmployeeAttributes.for(revision))` — **no password** (`encrypted_password` defaults to `""`), so the record
cannot authenticate until an account is enabled. Evidence that "User without Employee" is intended but not modelled:
every `User` is currently treated as an employee by `EmployeeScope` (§3.3).

### 3.3 Scheduling eligibility (Workforce responsibility)

Scheduling eligibility — *who can be scheduled / assigned to shifts* — is a **Workforce** concern. Owners, administrators
and remote employees must **not** appear in scheduling or shift-assignment workflows merely because they have a User
account.

Current behaviour (documented, not changed): there is no scheduling-eligibility attribute. Shift-assignment employee
pickers come from `EmployeeScope` (`ShiftAssignmentsController#load_form_data`), whose business-wide set is **every
business user except the viewer** (`EmployeeScope#base`) — so an owner appears to non-owner business-scoped managers,
and any user account can be selected. A future Workforce change should make eligibility explicit (an Employee-level
property); no behaviour change is part of this document.

## 4. Organization & Access

1. **Purpose.** Define the tenant, its branches, the User accounts that may access it, and what each account may do and see.
2. **Responsibilities.** Business record and settings storage; branches (geofence fields, branch/area manager); User accounts (authentication, credentials, status, locale, business membership); roles, permission catalogue and dependencies; access scopes (self/branch/area/business); segregation of duties.
3. **Models.** `Business`, `Branch`, `User` (account concern — §3), `PermissionRole`, `UserAuditLog`.
4. **Tables.** `businesses`, `branches`, `users` (shared, column stewardship §3.2), `permission_roles`, `user_audit_logs`.
5. **Controllers.** `users/sessions`, `users/registrations`, `admin/branches`, `admin/settings`, `admin/permission_roles`, `admin/user_passwords`, `profile/passwords`, `preferences`, `locale`, `api/v1/sessions`; the **account part** of `admin/users` (`toggle_active`, `transfer_ownership`, `permission_role_id`, login identifiers — §20).
6. **Services.** `EmployeeScope`, `BranchScope`, `Users::RegistrationService`, `Approvals::SelfApproval`.
7. **Queries.** Scope resolution inside `EmployeeScope` / `BranchScope` / `ApplicationPolicy::Scope` helpers.
8. **Jobs.** None.
9. **Policies.** `branch`, `permission_role` (+ access rules consumed by every domain's policies).
10. **Routes / API.** Devise routes, `/admin/branches`, `/admin/settings`, `/admin/permission_roles` (+ `assign_user`/`remove_user`), `/admin/users/:id/password`, `/admin/users/:id/toggle_active`, `/admin/users/:id/transfer_ownership`, `/profile/password`, `/preferences/locale`, `/locale`; `POST /api/v1/auth/login`, `DELETE /api/v1/auth/logout`. Declared but unimplemented: `/api/v1/businesses`, `/api/v1/branches`, `/api/v1/users`.
11. **Business rules.** Owner has all permissions; permission groups/dependencies; scope resolution; inactive accounts cannot sign in; login by email or phone; creator ≠ approver (`Approvals::SelfApproval`, used by WF, FS and IP approvals); owner cannot be deactivated (`admin/users#toggle_active`); business timezone/currency.
12. **Dependencies.** None on other domains in the target design. Today: `EmployeeScope`/`BranchScope` read branch membership only through OA's `OrganizationAccess::MembershipProvider` contract (Pilot 5); classified exceptions remain: `admin/branches` shows staff, the API login payload's `checkin_branch_ids`, and `User`/`Branch has_many :shift_assignments` plus `User#effective_shift_assignment_on`; `Branch` nested-writes `pos_terminals` (FS); inverse `has_many` on `Business`/`Branch`/`User`. Resolutions in §12–§14.
13. **Owns.** Businesses, business-settings storage, branches, user-account columns, permission roles, user audit log.
14. **May read.** Branch membership through the **membership contract** (defined by OA, implemented by WF — dependency inversion).
15. **Must NOT directly modify.** Employee profile columns, `shift_assignments`, `pos_terminals`, any other domain's tables.
16. **Public interfaces (future).** `can?(user, permission)`; `visible_employee_ids(user, permission)`; `visible_branch_ids(user, permission)`; `self_approval_allowed?(actor, record)`; account lifecycle (`create_account_for(employee)`, `enable_login`, `deactivate`, `assign_role`); branch lookup within a business; `settings_for(business, domain)`; membership contract (interface definition only).
17. **Events it may publish.** `user.account_created`, `user.deactivated`, `user.reactivated`, `user.role_changed`, `branch.created`, `branch.manager_changed`, `business.settings_changed`.
18. **Events it may consume.** `employee.onboarded` (offer account creation) — optional.

## 5. Workforce

1. **Purpose.** Manage Employees: who they are, how they are employed, where and when they work, what they request, how they perform.
2. **Responsibilities.** Employee profile and employment information; onboarding lifecycle (employee data requests); insurance profile; departments and job titles; branch assignments, shifts, templates, rule profiles; **scheduling eligibility**; employee requests workflow; performance reviews and observations; birthday celebration.
3. **Models.** `EmployeeDataRequest`, `EmployeeDataRequestEvent`, `EmployeeDataRequestRevision`, `EmployeeInsuranceProfile`, `Department`, `JobTitle`, `Shift`, `ShiftAssignment`, `ShiftTemplate`, `ShiftTemplateEntry`, `ShiftRuleProfile`, `EmployeeRequest`, `EvaluationTemplate`, `EvaluationCriterion`, `PerformanceReview`, `PerformanceReviewScore`, `PerformanceObservation`; Employee columns on `users` (§3.2).
4. **Tables.** `employee_data_requests`, `employee_data_request_events`, `employee_data_request_revisions`, `employee_insurance_profiles`, `departments`, `job_titles`, `shifts`, `shift_assignments`, `shift_templates`, `shift_template_entries`, `shift_rule_profiles`, `employee_requests`, `evaluation_templates`, `evaluation_criteria`, `performance_reviews`, `performance_review_scores`, `performance_observations`.
5. **Controllers.** Employee part of `admin/users` (index/new/create/show/edit/update/destroy of profile data), `admin/employee_insurance_profiles`, `admin/departments`, `admin/job_titles`, `admin/evaluation_templates`, `admin/shifts`, `admin/shift_templates`, `admin/shift_rule_profiles`, `shifts`, `shift_assignments`, `employee_requests`, `employee_data_requests`, `birthday_celebrations`, `performance/*`, `api/v1/shifts`, `api/v1/shift_assignments`, `api/v1/employee_requests`.
6. **Services.** `employee_data_requests/*`, `employee/insurance_profile_updater`, `dashboard/birthdays`, `BranchMembership`, `shifts/*`, `scheduling/*`, `requests/*`, `performance/*`.
7. **Queries.** `ShiftAssignment` scopes (`current`, `active_on`, `user_ids_for_branches`, `branch_ids_for_users`), `BranchMembership`, `Performance::Analytics`.
8. **Jobs.** None.
9. **Policies.** `user` (employee management), `employee_data_request`, `employee_insurance_profile`, `department`, `job_title`, `shift`, `shift_assignment`, `shift_template`, `shift_rule_profile`, `employee_request`, `evaluation_template`, `evaluation_criterion`, `performance_review`, `performance_observation`.
10. **Routes / API.** `/admin/users` (employee profile), `/admin/users/:id/employee_insurance_profile`, `/admin/departments`, `/admin/job_titles`, `/admin/evaluation_templates`, `/admin/shifts`, `/admin/shift_templates`, `/admin/shift_rule_profiles`, `/shifts/:id`, `/shift_assignments` (+ bulk), `/employee_requests`, `/employee_data_requests`, `/birthday_celebration`, `/performance/*`; `/api/v1/shifts…`, `/api/v1/shift_assignments…`, `/api/v1/employee_requests…`.
11. **Business rules.** Employee code generation (advisory lock); job title from catalogue; onboarding duplicate guard/verification; branch membership only from active shift assignments; effective assignment with temporary coverage; no overlapping assignments/shift times; template application with conflict detection; request rules (no self-approval, attendance-window checks, punch-correction assessment); business-scoped resource validation on assignment creation; performance scoring/averages.
12. **Dependencies.** OA only in the target design. Today also: requests write AP data; `Employee::InsuranceProfileUpdater` commands payroll recalculation (since Pilot 8 only through the WF contract `Employee::InsuranceProfileEffects`); `admin/users/show` reads salary profiles (AP); request validation reads attendance/advance eligibility (AP). Resolutions: events + contracts defined by WF and implemented by AP (§12, §14).
13. **Owns.** Tables in item 4; Employee columns on `users`.
14. **May read.** OA accounts, branches, roles.
15. **Must NOT directly modify.** User account data (§3.2); `advances`, `payroll_line_items`, `payroll_entries`, `attendance_records`, `penalty_rules` (AP).
16. **Public interfaces (future).** Employee directory (active/eligible employees, profile summary); `schedulable_employees(branch, date)`; `effective_assignment(employee, date)`; membership provider (implements OA's contract); shift definitions (times, type, rule profile); request status/approved requests per employee & period; performance scores; **request-effect contracts** that AP implements: `RequestEligibility` (e.g. advance eligibility, attendance-window facts) and `RequestEffects` (apply/revert effects of approved/cancelled requests).
17. **Events it may publish.** `employee.onboarded`, `employee.profile_changed`, `employee.insurance_profile_changed`, `employee.terminated/deactivated`, `shift_assignment.created/ended`, `employee_request.approved`, `employee_request.cancelled`, `employee_request.paid`, `performance_review.finalized`.
18. **Events it may consume.** `user.deactivated` (from OA).

## 6. Attendance & Payroll

1. **Purpose.** Turn time worked into pay.
2. **Responsibilities.** Attendance capture (mobile, device, manual, CSV), geofencing, adjustments, time/overtime calculation, **penalty rules and penalty calculation**, anomalies; salary profiles; payroll periods, entries, items; bonuses, commissions, deductions, adjustments; overrides/waivers/cancellations; **advances** (issue, eligibility, deduction, settlement); obligations; review → finalization → payment; payroll exports and analytics; attendance-based score (`Employee::PerformanceScorer`).
3. **Models.** `AttendanceRecord`, `AttendanceAdjustment`, `AttendanceImportLog`, `BiometricDevice`, `BiometricPunchLog`, `PenaltyRule`, `SalaryProfile`, `PayrollPeriod`, `PayrollEntry`, `PayrollLineItem`, `PayrollAdjustment`, `PayrollAdjustmentEdit`, `PayrollAuditLog`, `PayrollSnapshot`, `PayrollPeriodBranchReview`, `Advance`, `EmployeeObligation`, `ObligationDeduction`, `ObligationPostponement`; `Geo::Haversine` (library).
4. **Tables.** `attendance_records`, `attendance_adjustments`, `attendance_import_logs`, `biometric_devices`, `biometric_punch_logs`, `penalty_rules`, `salary_profiles`, `payroll_periods`, `payroll_entries`, `payroll_line_items`, `payroll_adjustments`, `payroll_adjustment_edits`, `payroll_audit_logs`, `payroll_snapshots`, `payroll_period_branch_reviews`, `advances`, `employee_obligations`, `obligation_deductions`, `obligation_postponements`.
5. **Controllers.** `attendance`, `attendance_records`, `admin/attendance_records`, `admin/attendance_imports`, `admin/biometric_devices`, `admin/biometric_punch_logs`, `admin/penalty_rules`, `admin/salary_profiles`, `admin/employee_obligations`, `adjustments`, `bulk_adjustments`, `payroll_periods`, `payroll_entries`, `payroll_line_items`, `payroll_adjustments`, `payroll_dashboard`, `api/v1/attendance`, `api/v1/punches`, `api/v1/attendance_records`, `api/v1/penalty_rules`, `api/v1/advances`, `api/v1/salary_profiles`, `api/v1/payroll_*`, `api/v1/reports/attendance`, `api/v1/reports/payroll`.
6. **Services.** `attendance/*`, `payroll/*`, `salary/*`, `adjustments/*`, `reports/{attendance_summary,payroll_summary,payroll_csv_exporter,bank_transfer_csv_exporter}`, `employee/performance_scorer`.
7. **Queries.** `Reports::AttendanceSummary`, `Payroll::PeriodFinancialSummary`, `Adjustments::SummaryData`, `Attendance::DailyStats`.
8. **Jobs.** `Payroll::AutoGenerateJob`; rake `lib/tasks/attendance.rake`.
9. **Policies.** `attendance_record`, `attendance_import_log`, `penalty_rule`, `salary_profile`, `payroll_period`, `payroll_entry`, `payroll_line_item`, `payroll_adjustment`, `advance`, `employee_obligation`, `payroll_dashboard`.
10. **Routes / API.** `/attendance/*`, `/attendance_records` (+ bulk, import), `/admin/attendance_*`, `/admin/biometric_*`, `/admin/shifts/:id/penalty_rules`, `/admin/users/:id/salary_profiles`, `/admin/employee_obligations`, `/adjustments`, `/bulk_adjustments`, `/payroll_periods/*`, `/payroll_dashboard`; `/api/v1/attendance/*`, `/api/v1/attendance/punch`, `/api/v1/attendance_records…`, `/api/v1/shifts/:id/penalty_rules…`, `/api/v1/advances…`, `/api/v1/users/:id/salary_profiles…`, `/api/v1/payroll_*…`, `/api/v1/reports/*`.
11. **Business rules.** Work date by business day; geofence; punch window & spam rejection; worked/late/early/overtime minutes; penalty money from penalty rules; daily rate & overtime pay; entry calculation; draft regeneration on attendance change; advance eligibility/deduction/settlement at `paid`; obligation deductions; waivers/overrides preserved on regeneration; creator ≠ approver on adjustments; lifecycle draft → under_review → branch_review_completed → finalized → paid (+ reopen); period lock; auto-generation; employer insurance cost computed at finalization.
12. **Dependencies.** OA (users, branches, business settings) and WF (assignments, shifts, rule profiles, requests). Implements WF's request contracts. Publishes financial effects for FS (no calls into FS).
13. **Owns.** Tables in item 4; attendance-channel columns on `users` (§3.2).
14. **May read.** WF assignments, shifts, rule profiles, approved requests; OA branches, users, settings.
15. **Must NOT directly modify.** `expenses` or any FS table; `shift_assignments`, `employee_requests` (WF); User account data (OA).
16. **Public interfaces (future).** `attendance_summary(employee_ids, period)`; `attendance_record_for(employee, work_date)`; `period_status(period)`; `payroll_totals(branch/employee, period)`; `labour_cost(branch, period)`; `advance_balance(employee)`; implementations of WF's `RequestEligibility` / `RequestEffects`.
17. **Events it may publish.** `attendance.record_changed` (internal), **`payroll.period_finalized`** (with its financial effects, e.g. employer insurance cost), `payroll.period_paid`, `payroll.period_reopened`, `advance.issued`, `advance.paid`, `advance.settled`.
18. **Events it may consume.** `employee_request.approved/cancelled/paid`, `employee.insurance_profile_changed`, `shift_assignment.created/ended`, `user.deactivated`.

## 7. Inventory & Purchasing

1. **Purpose.** Track physical goods: purchased, received, stored, moved, consumed, counted — including laundry consumables and towels.
2. **Responsibilities.** Warehouses and **warehouse access (`WarehouseAssignment`)**; products, categories, brands, barcodes; stock ledger / inventory movements and costing; issue vouchers (stock issues, import batches), transfers, adjustments, counts; suppliers; purchase requests; receiving / goods receipts; laundry towels, batches, consumption, cost rates; inventory & laundry reports.
3. **Models.** `Warehouse`, `WarehouseAssignment`, `WarehouseBranchSupply`, `Product`, `ProductBarcode`, `ProductCategory`, `Brand`, `ProductWarehouseSetting`, `InventoryMovement`, `StockIssue`, `StockIssueItem`, `StockIssueImportBatch`, `StockIssueImportRow`, `StockTransfer`, `StockTransferItem`, `StockAdjustment`, `StockAdjustmentItem`, `StockCount`, `StockCountItem`, `Supplier`, `PurchaseRequest`, `PurchaseRequestItem`, `PurchaseRequestAdvance`, `GoodsReceipt`, `GoodsReceiptItem`, `TowelType`, `TowelLedgerEntry`, `TowelTransfer`, `TowelTransferItem`, `TowelAdjustment`, `LaundryBatch`, `LaundryBatchConsumption`, `LaundryStandardCostRate`, `Service` (inactive, §20).
4. **Tables.** Tables of the models above; `product_variants` (legacy, §20).
5. **Controllers.** `inventory/*`, `laundry/*` (including their dashboards and reports).
6. **Services.** `inventory/*`, `laundry/*`.
7. **Queries.** `Inventory::LowStockQuery`, `StockLevels`, `ConsumptionLedger`, `BranchSupplyMap`, `inventory/reports/*`, `Laundry::TowelBalances`.
8. **Jobs.** None; rake `lib/tasks/laundry.rake` (`laundry:setup`).
9. **Policies.** `warehouse`, `warehouse_branch_supply`, `product`, `product_category`, `brand`, `supplier`, `purchase_request`, `goods_receipt`, `stock_issue`, `stock_transfer`, `stock_adjustment`, `stock_count`, `towel_type`, `towel_transfer`, `towel_adjustment`, `laundry_batch`, `laundry_standard_cost_rate`.
10. **Routes / API.** `/inventory/*`, `/laundry/*`. No API.
11. **Business rules.** Per-warehouse ledger stock; moving-average cost; posted documents immutable, corrections by void/reversal; approval gates (stock issues, goods receipts, purchase requests, stock counts) with no self-approval; imports never post directly; number sequencing; barcodes; purchase-request remaining quantities; laundry consumption posted to the ledger; towel balances.
12. **Dependencies.** OA (branches, users, permission groups). Publishes purchase/receipt financial effects for FS (no calls into FS in the target design).
13. **Owns.** Tables in item 4.
14. **May read.** OA branches/users/permissions.
15. **Must NOT directly modify.** `financial_settlements`, `custody_transactions`, `custody_accounts`, `expenses` (FS).
16. **Public interfaces (future).** `stock_level(product, warehouse)`; `post_consumption(...)` (internal to IP); `consumption(branch_ids, period)`; `goods_receipt_summary(receipt)` (number, supplier, total, status — for FS display); `purchase_totals(supplier/branch, period)`; `towel_balances(branch)`.
17. **Events it may publish.** **`goods_receipt.approved` / `goods_receipt.posted`** (with the purchase financial effect: supplier, amount, funding intent), **`goods_receipt.voided`**, `stock_count.approved`, `stock.low`.
18. **Events it may consume.** `financial_settlement.recorded/reversed` (only if receipts must display payment status; can be read via FS interface instead).

## 8. Finance & Sales

1. **Purpose.** Account for money: spending, cash handled each business day, deposits reaching the bank, sales recorded by external systems, and the financial effects of other domains' events.
2. **Responsibilities.** Expenses & recurring expenses; custody accounts/ledger & balance requests; financial settlements (incl. settlement of goods receipts); **payment methods**; daily reconciliation, till custody, deposits, refunds, depositor transfers, remaining deposit balances, **financial adjustments**; bank statements, matching, disputes; sales imports, POS/card imports, terminals; expense/custody reports; **recording financial effects** of payroll finalization and purchasing.
3. **Models.** `Expense`, `ExpenseAllocation`, `ExpenseCategory`, `ExpenseType`, `ExpenseTag`, `ExpenseTagging`, `RecurringExpense`, `RecurringExpenseAllocation`, `CustodyAccount`, `CustodyTransaction`, `BalanceRequest`, `FinancialSettlement`, `PaymentMethod`, `FinancialAdjustment`, `DailyReconciliation`, `TillSession`, `TillSessionAmount`, `TillHandover`, `TillHandoverAmount`, `TillDeposit`, `TillRefund`, `DepositResponsibilityTransfer`, `RemainingDepositBalance`, `RemainingDepositBalanceTransaction`, `EmployeeReconciliationSummary`, `EmployeeReconciliationSummaryAmount`, `BankStatement`, `BankStatementTransaction`, `DepositMatch`, `BankDispute`, `SalesImport`, `SalesTransaction`, `PosImport`, `PosImportIgnoredRow`, `PosTransaction`, `PosTerminal`, `BranchRevenue` (legacy, §20).
4. **Tables.** Tables of the models above.
5. **Controllers.** `finance/*` except `dashboard` and cross-domain reports; `till_handovers`, `till_deposits`, `till_refunds`, `opening_floats`, `deposit_responsibility_transfers`; in the target design also the goods-receipt settlement workflow (today `inventory/goods_receipt_settlements`, §14).
6. **Services.** `finance/*` (cash, bank, sales, POS, expenses, custody, single-domain reports), `FinancialSettlementService`.
7. **Queries.** `Finance::CustodyBalance`, `Finance::EmployeeReconciliationSummarizer`, `Finance::Reports::*` (expense/custody), `Finance::PosVerification::Comparator`.
8. **Jobs.** `Finance::GenerateDueRecurringExpensesJob`; rake `lib/tasks/finance.rake`, `lib/tasks/pos.rake`.
9. **Policies.** Expense, custody, balance request, financial adjustment, payment method, DR/till/deposit/refund/transfer/RDB, bank, deposit verification, sales/POS import policies.
10. **Routes / API.** `/finance/*` (except dashboard/cross-domain reports), `/till_*`, `/opening_floats`, `/deposit_responsibility_transfers`, `/my_shift` (deprecated). No API.
11. **Business rules.** One DR per branch per business day; DR aggregate root; `TillHandoverCreator` sole entry point; derived custody holder; opening float before operations; branch review gate; voids never deletes; append-only RDB and settlement ledgers; custody balance = SUM(non-voided signed amounts); expense approval without self-approval; idempotency on deposits/refunds; import duplicate prevention and DR matching; bank matching engine; POS fee expenses; system expenses (insurance) idempotent per period (partial unique index).
12. **Dependencies.** OA (branches, users); reads WF (who is on shift — till handover screen) and AP/IP through their interfaces; **consumes** AP and IP financial-effect events.
13. **Owns.** Tables in item 4.
14. **May read.** OA; WF membership/schedule (read interface); AP period reference/summary; IP goods-receipt summary.
15. **Must NOT directly modify.** Any IP, AP, WF or OA table; inventory logic (no stock, costing or receipt-state changes).
16. **Public interfaces (future).** `record_financial_effect(source:, …)` (system expenses); settlement of goods receipts (`FinancialSettlementService.record/reverse/reverse_all` — already exists); `custody_balance(account)`; `expense_totals(...)`; `reconciliation_for(branch, business_date)`; `deposit_totals(...)`; `sales_totals(...)`; `verified_revenue(branch, period)`.
17. **Events it may publish.** `daily_reconciliation.closed/deposited/verified`, `deposit.voided`, `expense.approved/paid`, `financial_settlement.recorded/reversed`, `sales_import.completed`.
18. **Events it may consume.** **`payroll.period_finalized`** (record employer insurance expense), `payroll.period_paid` / `advance.paid` (reserved — no financial record exists for these today), **`goods_receipt.approved/posted`** (record purchase financial effect / settlement when paid at receipt), **`goods_receipt.voided`** (reverse settlements).

## 9. Reporting

1. **Purpose.** Answer cross-domain questions without owning business data.
2. **Responsibilities.** Dashboards, reports, analytics and cross-domain aggregations only.
3. **Models / 4. Tables.** None.
5. **Controllers.** `dashboard` (home), `operations_dashboard`, `admin/dashboard`, `finance/dashboard` (+ PDF export), cross-domain `finance/reports` actions (`branch_profitability`), `laundry/reports/cost_summary` (Reporting UI under the laundry URL, Pilot 11).
6. **Services.** `dashboard/{owner_data,area_manager_data}`, `finance/dashboard/*`, `finance/dashboard_filters`, `finance/reports/{branch_profitability,expense_sources,verified_revenue,laundry_cost_summary,expense_details,expense_details_csv_exporter}` (`laundry_cost_summary`: the whole laundry operating-cost report, reads AP + WF + FS + IP — Pilot 11; `expense_details` + its CSV: the per-source breakdown of profitability costs, cross-domain through `expense_sources` — classified in Batch R). The other `finance/reports/*` files are single-domain Finance & Sales reports and FS report infrastructure (D-R1). `Finance::ReportsController` is an FS controller hosting the two Reporting actions `branch_profitability` and `expense_details`.
7. **Queries.** The services above.
8. **Jobs.** None.
9. **Policies.** `operations_dashboard`, `finance/dashboard`.
10. **Routes / API.** `/`, `/operations_dashboard`, `/admin`, `/finance`, `/finance/dashboard/export_pdf`, `/finance/reports/branch_profitability`, `/laundry/reports/cost_summary`. No API.
11. **Business rules.** Presentation/aggregation only (section gating by permission, profitability composition, period resolution).
12. **Dependencies.** Reads all five domains (today: AP 36 refs / 7 files, FS 34 / 12, WF 16 / 8, OA 16 / 8, IP 13 / 5).
13. **Owns.** Nothing. 14. **May read.** Every domain via query interfaces. 15. **Must NOT modify.** Anything.
16. **Interfaces.** None (consumer). 17. **Publishes.** None. 18. **Consumes.** Any event, only to refresh read models/caches.

---

## 10. Model Ownership

| Domain | Models |
|---|---|
| **Organization & Access** | `Business`, `Branch`, `User` (account concern), `PermissionRole`, `UserAuditLog` |
| **Workforce** | Employee (concept; columns on `users` §3.2), `EmployeeDataRequest`, `EmployeeDataRequestEvent`, `EmployeeDataRequestRevision`, `EmployeeInsuranceProfile`, `Department`, `JobTitle`, `Shift`, `ShiftAssignment`, `ShiftTemplate`, `ShiftTemplateEntry`, `ShiftRuleProfile`, `EmployeeRequest`, `EvaluationTemplate`, `EvaluationCriterion`, `PerformanceReview`, `PerformanceReviewScore`, `PerformanceObservation` |
| **Attendance & Payroll** | `AttendanceRecord`, `AttendanceAdjustment`, `AttendanceImportLog`, `BiometricDevice`, `BiometricPunchLog`, `PenaltyRule`, `SalaryProfile`, `PayrollPeriod`, `PayrollEntry`, `PayrollLineItem`, `PayrollAdjustment`, `PayrollAdjustmentEdit`, `PayrollAuditLog`, `PayrollSnapshot`, `PayrollPeriodBranchReview`, `Advance`, `EmployeeObligation`, `ObligationDeduction`, `ObligationPostponement` (+ `Geo::Haversine` library) |
| **Inventory & Purchasing** | `Warehouse`, `WarehouseAssignment`, `WarehouseBranchSupply`, `Product`, `ProductBarcode`, `ProductCategory`, `Brand`, `ProductWarehouseSetting`, `InventoryMovement`, `StockIssue`, `StockIssueItem`, `StockIssueImportBatch`, `StockIssueImportRow`, `StockTransfer`, `StockTransferItem`, `StockAdjustment`, `StockAdjustmentItem`, `StockCount`, `StockCountItem`, `Supplier`, `PurchaseRequest`, `PurchaseRequestItem`, `PurchaseRequestAdvance`, `GoodsReceipt`, `GoodsReceiptItem`, `TowelType`, `TowelLedgerEntry`, `TowelTransfer`, `TowelTransferItem`, `TowelAdjustment`, `LaundryBatch`, `LaundryBatchConsumption`, `LaundryStandardCostRate`, `Service` (inactive) |
| **Finance & Sales** | `Expense`, `ExpenseAllocation`, `ExpenseCategory`, `ExpenseType`, `ExpenseTag`, `ExpenseTagging`, `RecurringExpense`, `RecurringExpenseAllocation`, `CustodyAccount`, `CustodyTransaction`, `BalanceRequest`, `FinancialSettlement`, `PaymentMethod`, `FinancialAdjustment`, `DailyReconciliation`, `TillSession`, `TillSessionAmount`, `TillHandover`, `TillHandoverAmount`, `TillDeposit`, `TillRefund`, `DepositResponsibilityTransfer`, `RemainingDepositBalance`, `RemainingDepositBalanceTransaction`, `EmployeeReconciliationSummary`, `EmployeeReconciliationSummaryAmount`, `BankStatement`, `BankStatementTransaction`, `DepositMatch`, `BankDispute`, `SalesImport`, `SalesTransaction`, `PosImport`, `PosImportIgnoredRow`, `PosTransaction`, `PosTerminal`, `BranchRevenue` (legacy) |
| **Reporting** | — (owns no models) |
| **Infrastructure** | `AuditLog`, `ApplicationRecord` |

### 10.1 Rationale for the supporting-model decisions

| Model | Domain | Why (repository evidence) |
|---|---|---|
| "EmployeeUserProfile" | **Workforce** | **No model with this name exists.** The employee-profile data it describes lives in Employee columns on `users` (§3.2) and in `EmployeeInsuranceProfile` (HR insurance data per employee, edited at `/admin/users/:id/employee_insurance_profile`, `EmployeeInsuranceProfilePolicy`). Both are Workforce. Naming to be confirmed (§20) |
| `EmployeeInsuranceProfile` | **Workforce** | HR attribute of the employee; its payroll effect (deductions, employer cost) is consumed by AP via `employee.insurance_profile_changed` |
| `Department` | **Workforce** | Employee attribute (`users.department_id`), required by performance templates/reviews (`EvaluationTemplate.department`, `PerformanceReview.department`); routes group it under "Performance: Department Settings" |
| `JobTitle` | **Workforce** | Catalogue that validates the employee's `job_title` (`User#job_title_from_catalog`) |
| `PenaltyRule` | **Attendance & Payroll** | Its only consumers are penalty calculation (`Attendance::PenaltyCalculator`, `TimeCalculator`) used by payroll entry calculation, `PermissionApplier` and (since Pilot 10) the recalculation behind `Attendance::PunchCorrectionEffects`. It is *attached to* a WF `Shift` and edited on the shift screens (`admin/shifts/:id/penalty_rules`, `api/v1/shifts/:id/penalty_rules`, `Shift accepts_nested_attributes_for :penalty_rules`) — a UI composition to route through AP (§14 #9) |
| `PurchaseRequestAdvance` | **Inventory & Purchasing** | The lifecycle of an advance paid against a Purchase Request (record / confirm / cancel / reverse, row locks, capacity, audits — `Inventory::PurchaseRequestAdvanceRecorder` / `Workflow`). Its money lives in FS ledgers it only references (`financial_settlement`, `custody_account`, receipt-side `applications`); since S2 the ledger writes and custody choice go through `Inventory::PurchaseRequestAdvanceEffects` (FS implementation). Added to this map in S2 (it was missing) |
| `WarehouseAssignment` | **Inventory & Purchasing** | Restricts which warehouses a user may see (`User#inventory_warehouse_ids`, `ApplicationPolicy::Scope#for_accessible_warehouses`) — inventory access, not a workforce assignment |
| `Geo::Haversine` (`lib/geo/haversine.rb`) | **Attendance & Payroll** | Its only consumer is `Attendance::GeolocationValidator` |
| `PaymentMethod` | **Finance & Sales** | All six foreign keys to `payment_methods` come from cash tables (`till_deposits`, `till_handover_amounts`, `till_session_amounts`, `till_refunds`, `remaining_deposit_balance_transactions`, `employee_reconciliation_summary_amounts`) |
| `FinancialAdjustment` | **Finance & Sales** | Polymorphic `adjustable` points only at cash records (handover, deposit, remaining balance, session amount, DR); created by `Finance::TillHandoverAdjuster`; append-only |
| `Advance` | **Attendance & Payroll** | Deducted and settled by payroll (`Payroll::AdvanceDeductor`, settlement at `paid` in `Payroll::Approver`); eligibility in `Salary::AdvanceEligibilityCalculator` |
| `Employee::PerformanceScorer` (service) | **Attendance & Payroll** | Attendance-based score; callers are `OperationsDashboardController` (read by Reporting) and `Payroll::RecommendationEngine`; unrelated to `PerformanceReview` |

## 11. Database Ownership

Tables follow model ownership (§10). No migrations, renames or moves are proposed.

| Table | Owner | Notes |
|---|---|---|
| `users` | **OA** (account) with **WF** and **AP** column stewardship | §3.2 |
| `businesses` | **OA** (storage) | Other domains' settings stored here — §20 |
| `branches` | OA | Branch/area managers drive access scopes |
| `shift_assignments` | WF | Also backs OA's membership contract |
| `penalty_rules` | AP | Attached to WF `shifts` by foreign key |
| `warehouse_assignments` | IP | User ↔ warehouse access |
| `advances` | AP | Row created by WF request approval today (§14) |
| `expenses` | FS | `source_payroll_period_id` / `source_pos_import_id` mark system rows |
| `financial_settlements`, `custody_transactions` | FS | Polymorphic references to `goods_receipts` (IP) — references only |
| `inventory_movements` | IP | Laundry consumption rows written inside IP |
| `payment_methods`, `financial_adjustments` | FS | §10.1 |
| `pos_terminals` | FS | Edited on OA's branch form; written only through the OA contract `OrganizationAccess::BranchTerminalSettings`, implemented by FS (Pilot 12, §14.2 #8) |
| `audit_logs` | Infrastructure | Polymorphic cross-domain audit |
| `payroll_audit_logs` / `user_audit_logs` | AP / OA | Domain audit trails |
| `notifications` | Legacy (Infrastructure) | §20 |
| `product_variants` | Legacy (IP) | §20 |
| `services` | IP (inactive) | §20 |
| `branch_revenues` | FS (legacy) | §20 |
| `solid_queue_*`, `solid_cache_entries`, `solid_cable_messages`, `active_storage_*` | Infrastructure | |

## 12. Dependency Graph

### 12.1 Target graph (six domains only)

Arrows point **downstream**: a downstream domain depends on (knows about) the upstream domains above it.
An upstream domain never calls or writes into a downstream domain.

```
            Organization & Access
                     │
                     ▼
                 Workforce
                     │
                     ▼
            Attendance & Payroll          Inventory & Purchasing
                     │                               │
                     └──────────────┬────────────────┘
                                    ▼
                             Finance & Sales

            Reporting ── reads from all five domains (read-only)
```

| Allowed dependency | What is consumed | Mechanism |
|---|---|---|
| WF → OA | User accounts (association, account status), branches, roles/scopes | Public interface |
| AP → WF | Assignments, shifts, rule profiles, approved requests; implements WF's request contracts | Public interface + event subscription (WF events) |
| AP → OA | Branches, users, business settings | Public interface |
| IP → OA | Branches, users, permission groups | Public interface |
| FS → AP | Payroll financial effects (`payroll.period_finalized`), period reference/labels | Event subscription + read interface |
| FS → IP | Purchase/receipt financial effects (`goods_receipt.*`), receipt summary for display | Event subscription + read interface |
| FS → WF, FS → OA | Staff on shift (till screens), branches, users | Read interface |
| RP → all | Everything it aggregates | Read interfaces only |

**Upstream needs for downstream data are handled by inversion, never by an upward dependency:**

| Need | Resolution |
|---|---|
| OA access scopes need branch membership (WF) | **Implemented (Pilot 5):** OA defines `OrganizationAccess::MembershipProvider` (`current_branch_ids`, `current_member_ids`); WF implements it (`Workforce::MembershipProvider` → `BranchMembership`), registered at boot in `config/initializers/organization_access_membership_provider.rb`. `EmployeeScope` / `BranchScope` reference only the contract (enforced by `spec/architecture/organization_access_membership_boundary_spec.rb`) |
| WF request validation/effects need attendance & payroll facts (AP) | WF defines **`RequestEligibility`** and **`RequestEffects`** contracts and publishes `employee_request.*` events; AP implements/subscribes |
| WF employee page shows salary (AP) | **Implemented (SAL):** UI composition — WF defines `Employee::ProfilePanels` (`salary_panel(viewer:, employee:)` → `Panel(partial, locals)` or nil); AP implements it (`Payroll::EmployeeSalaryPanel`: `SalaryProfilePolicy` decision, current profile, `Salary::ViewAudit`) and owns the partial `admin/salary_profiles/_employee_panel`, registered in `config/initializers/employee_profile_panels.rb`; WF does not read AP. The obligations card stays the classified exception (SEC-M2-5). Enforced by `spec/architecture/workforce_employee_salary_panel_boundary_spec.rb` |
| ~~IP laundry cost report reads payroll/assignments (AP/WF)~~ | **Resolved (Pilot 11):** the whole report moved to **Reporting** (`Finance::Reports::LaundryCostSummary`) |
| OA branch form edits POS terminals (FS) | **Implemented (Pilot 12):** OA defines `OrganizationAccess::BranchTerminalSettings` (`assign(branch:, rows:)`); FS implements it (`Finance::BranchPosTerminals`, staging only), registered at boot in `config/initializers/branch_terminal_settings.rb`. OA code references only its own contract. Enforced by `spec/architecture/finance_sales_pos_terminal_boundary_spec.rb` |
| WF shift form edits penalty rules (AP) | **Implemented (Milestone 2, Pilot 4):** WF defines `Shifts::PenaltyRuleSettings`; AP implements it (`Attendance::ShiftPenaltyRules`), registered at boot in `config/initializers/shift_penalty_rule_settings.rb`. WF code references only its own contract |
| WF insurance profile change must update payroll; the insurance form shows which payroll it affects (AP) | **Implemented (Pilot 8):** WF defines `Employee::InsuranceProfileEffects` (`profile_changed`, `payroll_notice_for` → `:none`/`:active`/`:mixed`/`:finalized`); AP implements it (`Payroll::InsuranceProfileEffects`), registered at boot in `config/initializers/employee_insurance_profile_effects.rb`. Synchronous, called after the profile is committed; a failure is logged and never fails the change. AP still reads the profile itself for its snapshot (allowed direction). Enforced by `spec/architecture/workforce_employee_insurance_profile_boundary_spec.rb` |
| WF late / early-leave permission approval and cancellation must update payroll (AP) | **Implemented (Pilot 9):** WF owns the `EmployeeRequest` lifecycle and defines `Requests::PermissionPayrollEffects` (`permission_approved(request:)` → `nil`; `permission_cancelled(request:)` → `:reverted` / `:refused`, `:refused` only for a finalized / paid period, called inside the cancel transaction). AP owns the effect: `Payroll::PermissionPayrollEffects` → `Payroll::PermissionApplier` (approval) / `Payroll::PermissionReverter` (cancellation), registered at boot in `config/initializers/request_permission_payroll_effects.rb`; it never calls WF request services. Enforced by `spec/architecture/workforce_request_permission_payroll_boundary_spec.rb`. **Legacy exception:** the punch-correction rollback in `Requests::Canceller` still names AP, allowed only in its six methods (unreachable since Pilot 10 M4-2; **removed in Pilot 10 M6** — the canceller now names AP nowhere) |
| WF punch-correction assessment, approval and cancellation need attendance facts and must change attendance and payroll (AP) | **Implemented (Pilot 10, M2–M4):** WF owns the lifecycle, `approved_punch_at`, the snapshot, the audits and the messages, and defines `Requests::PunchCorrectionEffects` (`correction_facts` → `Facts`; `correction_approved(request:, field:, effective_at:, actor:)` → `Approval` with the replaced punches' `Snapshot`; `correction_cancelled(request:, field:, snapshot:, actor:)` → `:reverted` / `:no_attendance_record` / `:payroll_locked`), called inside the approve / cancel transaction after WF locks the request row. AP implements it (`Attendance::PunchCorrectionEffects`): record lookup, period lookup with `FOR UPDATE`, locked-period refusal, punch write / restore, recompute, and `Payroll::EntryRecalculator` for an existing entry only (entry row locked; lock order request → period → entry); registered in `config/initializers/request_punch_correction_effects.rb`. Enforced by `spec/architecture/workforce_punch_correction_boundary_spec.rb` |
| WF shift-assignment deletion needs to know whether attendance references the assignment (AP) | **Implemented (F2):** WF defines `Shifts::AttendanceUsage` (`recorded_against?(assignment_id:)` → Boolean; `recorded_against_sql(assignment_column:)` → the same question as a correlated SQL expression, so the assignment index keeps one `EXISTS` column and no per-row query). AP implements it (`Attendance::ShiftAssignmentUsage`, the former query and SQL unchanged), registered in `config/initializers/shift_attendance_usage.rb`. Enforced (constants **and** table names in SQL strings) by `spec/architecture/workforce_shift_scheduling_boundary_spec.rb` |
| WF salary-advance payment must record the Advance (AP) | **Implemented (Batch A):** WF owns the `EmployeeRequest` lifecycle and defines `Requests::AdvanceEffects` (`advance_paid(request:, paid_at:)` → `nil`), called by `Requests::Approver#pay` inside the pay transaction after the request row lock (F-A1). AP implements it (`Payroll::AdvanceEffects`, the same `Advance.create!`), registered at boot in `config/initializers/request_advance_effects.rb`. WF reads `request.advance` only at classified sites. Enforced by `spec/architecture/workforce_request_advance_boundary_spec.rb` |

The FS → AP payroll financial effect (Workflow A, §14.1) is implemented the same way (Milestone 2): AP defines
`Payroll::FinalizationEffects` — called synchronously inside the finalization / reopen transaction, carrying the
payroll-computed employer insurance cost — and FS implements it (`Finance::PayrollFinalizationEffects`), registered at
boot in `config/initializers/payroll_finalization_effects.rb`. Such boot-registered contracts are the in-process form
of rules 4–5 of §18.

### 12.2 Current state vs target (measured)

| Current edge | Refs / files | Target status |
|---|---|---|
| WF → OA | 49 / 27 | **Allowed** |
| AP → OA | 30 / 20 | **Allowed** |
| AP → WF | 25 / 19 | **Allowed** |
| FS → OA | 15 / 11 | **Allowed** |
| IP → OA | 13 / 8 | **Allowed** |
| RP → all | AP 36/7, FS 34/12, WF 16/8, OA 16/8, IP 13/5 | **Allowed** (read-only) |
| FS → AP (model: `Expense.source_payroll_period`) | 1 association | **Allowed** (reference) |
| FS → IP (model: polymorphic `GoodsReceipt`; custody account page) | 3 / 1 + associations | **Allowed** as reference + read interface |
| FS → WF (`TillHandoversController` → `ShiftAssignment`) | 1 file | **Allowed** via read interface |
| OA → WF (`EmployeeScope`/`BranchScope` → `BranchMembership`) | — | **Resolved (Pilot 5):** through the OA-defined membership contract |
| OA → WF (branch staff view, API login `checkin_branch_ids`, `User` helper / inverse associations) | 4 files | **Classified exceptions** (Pilot 5 M6, shape-pinned); targets: Reporting / composition, session payload via WF interface, User / Employee stewardship |
| OA → FS/IP/AP (inverse `has_many`; `WorkspaceHelper`; ~~branch form writes `pos_terminals`~~; ~~user form writes `warehouse_assignments`~~) | model + 2 files | **Classified exceptions (Batch W)**: the inverse associations of `Business`, `Branch` and `User` into WF / AP / IP / FS are listed per owning domain and frozen (a new one fails the spec); `WorkspaceHelper` is the UI-shell navigation registry, limited to `policy(Model)` gates and two workspace permission lists (`spec/architecture/organization_access_outbound_boundary_spec.rb`). Writes resolved: the branch-form terminal write **(Pilot 12)** through `OrganizationAccess::BranchTerminalSettings` (FS implementation); the user-form warehouse write **(Batch W)** through `OrganizationAccess::UserWarehouseAccess` (IP implementation). Moving the inverse associations to their owning domains stays the long-term target |
| WF → AP (request writes, salary display, request validation reads) | 19 / 9 | **Violation** → events + WF-defined contracts + UI composition. The insurance recalculation and payroll-notice edges are **resolved (Pilot 8)** through `Employee::InsuranceProfileEffects`. The permission payroll effects (approve / cancel of late and early-leave requests) are **resolved (Pilot 9)** through `Requests::PermissionPayrollEffects`. The punch-correction reads and writes (assessment, approval, cancellation) are **resolved (Pilot 10 M2–M4, on the pilot branch)** through `Requests::PunchCorrectionEffects`; the canceller's pre-M4 legacy rollback was removed in Pilot 10 M6. The salary-advance payment write is **resolved (Batch A)** through `Requests::AdvanceEffects`; WF's remaining reads of `request.advance` are classified exceptions (`workforce_request_advance_boundary_spec.rb`). The request-validation reads (D-A5) are **resolved (Batch V: M1 `180962f`, M2 `2f7cd91`, M3 `1d1def7`, M4 `84e7275`, on `batch-v/request-validation-reads-2`, not yet merged)** through the WF read contract `Requests::RequestFormReads`, implemented by AP (`Payroll::RequestFormReads`): the advance limit (`EmployeeRequest`), the form's limit hint with its salary-visibility decision and salary-view audit, the show page's attendance day, the form's recent check-ins (`EmployeeRequestsController`), the on-behalf salary-advance check (`EmployeeRequestPolicy`) and the duration thresholds of the request show page and its resulting-duration panel; enforced by `workforce_request_validation_reads_boundary_spec.rb` (`next-pilot-selection.md` §37). The shift-assignment attendance reads (`ShiftAssignment#has_attendance_records?` and the assignment index's raw `EXISTS … attendance_records`; cycle F2, undocumented here until the 2026-10-22 dependency inventory) are **resolved (F2, §41, on `migration/f2-shift-assignment-attendance`, not yet merged)** through the WF read contract `Shifts::AttendanceUsage`, implemented by AP. *Correction (2026-10-22):* the earlier statement "No WF → AP edge remains open" was inaccurate — F2 and the employee-page salary panel (`Admin::UsersController#load_salary` → `SalaryProfile`, `Salary::ViewAudit`; SAL) were open and unclassified (`docs/architecture/dependency-inventory-report.txt`). After F2, SAL was the remaining open WF → AP edge; it is **resolved (SAL, §42, on `migration/sal-employee-salary-panel`, not yet merged)** through the WF UI-composition contract `Employee::ProfilePanels`, implemented by AP. No unclassified WF → AP reference remains (dependency inventory); the other references are classified exceptions — the `request.advance` reads above, the shared helper's `PayrollAdjustment::POSITIVE_TYPES` badge (`application_helper.rb`, payroll screens), the obligations card (SEC-M2-5) and the Pilot 4 penalty-rule option lists |
| ~~AP → FS (`Payroll::InsuranceExpenseGenerator` writes `expenses`)~~ | — | **Resolved (Milestone 2, Pilot 3):** generator removed; AP calls only its `Payroll::FinalizationEffects` contract, FS implements it (cycle F3 eliminated) |
| ~~WF → AP penalty-rule write (`Shift` nested attributes, §14.2 #9)~~ | — | **Resolved (Milestone 2, Pilot 4):** WF `Shifts::PenaltyRuleSettings` contract, AP implementation; `Shift` keeps only the inverse lifecycle association (`dependent: :destroy, autosave: true`), a classified exception |
| IP → FS (goods-receipt settlement/void call `FinancialSettlementService`; custody accounts as funding source) | 6 / 6 | **Violation of direction** → `goods_receipt.*` events; settlement workflow owned by FS. **Goods-receipt write half resolved (Batch S: M2 `26f8192`, M3 `78a0c7d`, M4 `64f1f22`, M6 `165ebd1`, on `batch-s/goods-receipt-payments`, not yet merged):** approval (incl. advance application), later settlement, single reversal and void call the IP contract `Inventory::GoodsReceiptPaymentEffects`, implemented by FS (`Finance::GoodsReceiptPaymentEffects`), synchronously in the caller's transaction — the `goods_receipt.*` event target is deferred in favour of this interface (approved 2026-10-21). **Purchase Request advance half resolved (S2, `next-pilot-selection.md` §39, on `migration/s2-purchase-request-advances`, not yet merged):** deposit (confirmation), reversal and the advance's custody-account choice / form options call the IP contract `Inventory::PurchaseRequestAdvanceEffects`, implemented by FS (`Finance::PurchaseRequestAdvanceEffects`), synchronously in the caller's transaction. No IP → FS ledger write remains. What remains are the classified IP read sites (funding constants and totals on the models, the settlement / receiving screens' account previews, the draft's own-custody default), frozen by `inventory_finance_goods_receipt_payment_boundary_spec.rb` — an allowed reference direction for display, not a write |
| ~~IP → AP / IP → WF (`Laundry::LaundryCostSummaryReport`)~~ | — | **Resolved (Pilot 11):** the report aggregates four domains, so the whole of it moved to Reporting as `Finance::Reports::LaundryCostSummary` (RP → all, read-only); enforced by `spec/architecture/reporting_laundry_cost_summary_boundary_spec.rb` |

## 13. Circular Dependencies

| Previously identified cycle | Six-domain mapping | Real business dependency | Desired direction | What should happen eventually |
|---|---|---|---|---|
| Attendance ↔ Payroll | **Internal to AP** | Payroll pays for attendance; attendance changes refresh drafts | Payroll → Attendance | Internal event `attendance.record_changed` replaces direct calls from six attendance services to `Payroll::DraftRegenerator` |
| Employee Requests ↔ Payroll | **WF ↔ AP (cross-domain)** | Approved/cancelled requests change pay and attendance; request validation needs attendance/payroll facts | **AP → WF** only | WF publishes `employee_request.*`; AP subscribes and applies effects; validation via WF-defined `RequestEligibility` implemented by AP |
| Cash Management ↔ Sales Import | **Internal to FS** | Sales matched to the business day; DR shows sales totals | Sales area → Cash area | Internal service boundary only |
| Cash ↔ Bank reconciliation | **Internal to FS** | Deposits verified against statements; disputes on DR | — | Internal |
| Inventory ↔ Purchasing | **Internal to IP** | Receipts post stock; inventory screens show receipts | Purchasing area → Inventory area | Internal; purchase reports live in the Purchasing area |
| Inventory ↔ Laundry | **Internal to IP** | Laundry consumes stock; consumption reports include laundry | Laundry area → Inventory area | Internal `post_consumption` service |
| WF ↔ AP (shift assignments ↔ attendance, F2) | **WF ↔ AP (cross-domain)** | Attendance is matched to assignments; an assignment with attendance may not be hard-deleted | **AP → WF** only | **Resolved (F2):** WF asks through its `Shifts::AttendanceUsage` contract, AP implements it |
| OA ↔ WF (access scopes ↔ membership) | **OA ↔ WF (cross-domain)** | Authorization needs branch membership | **WF → OA** only | Membership contract (inversion) |
| IP ↔ FS (settlement ↔ polymorphic receipt) | **IP ↔ FS (cross-domain)** | Receipts create payables/settlements | **FS → IP** only | IP publishes receipt events; FS owns settlement, keeps polymorphic references. **Write direction inverted** by Batch S (goods receipts) and S2 (Purchase Request advances): IP calls only its own contracts, FS implements them; IP's remaining FS references are classified display reads |

After these resolutions the target graph (§12.1) is **acyclic**.

**Milestone 2 progress:** the AP ↔ FS insurance-expense cycle (F3 in `next-pilot-selection.md`) is **eliminated**
(Pilot 3). The WF ↔ AP penalty-rule write is inverted (Pilot 4); the WF ↔ AP employee-request cycle above and the
`Shift has_many :penalty_rules` lifecycle association remain, documented and enforced by boundary specs. The OA ↔ WF
access-scope edge is inverted through the membership contract (Pilot 5); four OA → WF read / lifecycle exceptions
remain, classified and enforced (`next-pilot-selection.md` §20.5).

## 14. Cross-Domain Workflows and Writes

**Rule:** a domain must not directly write to another domain's internal tables. To cause a state change in another
domain it calls that domain's explicit **public interface** or publishes a **domain event** that the owner consumes.
Events are in-process (same Rails application); where the current behaviour is transactional with the triggering
change, the handler must run inside the same database transaction (or an equivalent transactional outbox) so no
financial or payroll effect is lost or duplicated. **No HTTP between domains; no microservices.**

### 14.1 Documented workflows (target — not implemented)

**A. Payroll finalization → financial effect**
```
Attendance & Payroll: period finalized (Payroll::Approver)
  → event payroll.period_finalized { period, business, employer_insurance_cost_by_branch, … }
Finance & Sales: records the system expense(s) (idempotent per period — existing partial unique index)
```
**Implemented (Milestone 2, Pilot 3)** as the AP-defined, FS-implemented contract `Payroll::FinalizationEffects`
(synchronous, inside the finalization / reopen transaction): `Payroll::Approver` computes the employer insurance cost
(`Payroll::EmployerInsuranceCost`) and calls `period_finalized`; `Payroll::Reopener` calls `period_reopened`, which
voids the expense; FS records it (`Finance::PayrollInsuranceExpense`). `Payroll::InsuranceExpenseGenerator` no longer
exists. `payroll.period_paid` and `advance.paid` are reserved for future financial records; **no Finance record is
created for salary payment or advance disbursement today** (Reporting computes payroll cost from payroll entries).

**B. Advance request**
```
Workforce: employee submits salary-advance request → reviewer approves (Requests::Approver)
  → event employee_request.approved { request, type: salary_advance, amount }
Attendance & Payroll: creates the Advance (eligibility via Salary::AdvanceEligibilityCalculator)
Workforce: "pay" action → event employee_request.paid → Attendance & Payroll marks the advance paid
Attendance & Payroll: deducts on payroll; settles advances when the period is paid
```
Until Batch A, `Requests::Approver#pay` created `Advance` rows directly (approval creates nothing; `pay` — also reached
through `Requests::BulkPaymentService` — marks the request paid and creates the Advance). Since Batch A `pay` records it
through the WF-defined interface `Requests::AdvanceEffects.advance_paid(request:, paid_at:)` (synchronous, inside the
pay transaction after the F-A1 request lock — the interface form of this workflow); AP (`Payroll::AdvanceEffects`)
creates the Advance, deducts it (`Payroll::AdvanceDeductor`) and settles it (`Payroll::Approver`).

**C. Attendance adjustment requests (punch correction, late/early permission)**
```
Workforce: request approved
  → event employee_request.approved { request, type: punch_correction | late_permission | early_leave, … }
Attendance & Payroll: applies the attendance change (record recompute) and the payroll effect
  (Attendance::PunchCorrectionEffects → Payroll::EntryRecalculator / Payroll::PermissionApplier — AP services)
Workforce: request cancelled → event employee_request.cancelled
Attendance & Payroll: restores the pre-request attendance/payroll state from the request's snapshot
```
Until Pilot 10, `Requests::PunchCorrectionApplier` updated `AttendanceRecord` and `Requests::Canceller` restored/created
`PayrollLineItem` rows directly. Since Pilot 10 M4 both go through the WF-defined interface
`Requests::PunchCorrectionEffects` (synchronous, inside the approve / cancel transaction — the interface form of this
workflow); AP re-derives the entry with `Payroll::EntryRecalculator`.

**D. Goods receipt → purchase financial effect**
```
Inventory & Purchasing: goods receipt approved/posted (Inventory::GoodsReceiptApproval / GoodsReceiptPoster)
  → event goods_receipt.approved|posted { receipt, supplier, amount, funding intent }
Finance & Sales: records the settlement / custody transaction (FinancialSettlementService)
Inventory & Purchasing: receipt voided → event goods_receipt.voided
Finance & Sales: reverses all settlements (append-only reversal — FinancialSettlementService.reverse_all)
```
Finance & Sales may reference goods receipts (polymorphic `settleable` / `source`) and show receipt summaries, but owns
no inventory logic. Later settlements initiated by a user ("settle this receipt") are a **Finance & Sales workflow**
that reads the receipt through IP's interface (today `inventory/goods_receipt_settlements`).

**E. Employee onboarding → account**
```
Workforce: employee data request approved → Employee created (profile/employment data)
  → optional: Organization & Access creates/enables a User account through its interface
```
Today the approval creates a `users` row without a password (§3.2).

### 14.2 Current cross-domain writes (not fixed now)

| # | Current behaviour | Owner of data | Why it exists | Desired interaction | Interface vs event | Migration risk |
|---|---|---|---|---|---|---|
| 1 | **Resolved (Milestone 2, Pilot 3).** Was: `Payroll::InsuranceExpenseGenerator` creates `Expense` at finalization; now FS creates / voids it through `Payroll::FinalizationEffects` | FS | Employer insurance cost | Workflow A | **Event** `payroll.period_finalized` (transactional handler) | Medium — idempotency index must keep working; finalization must not succeed without the expense |
| 2 | **Resolved (Batch A).** Was: `Requests::Approver#pay` creates `Advance` directly; now it calls the WF contract `Requests::AdvanceEffects.advance_paid`, implemented by AP (`Payroll::AdvanceEffects`), inside the pay transaction after the request lock (F-A1) — the request and its Advance are written together or not at all. WF still reads `request.advance` at classified sites (paid-out checks, preloads, sort scope) | AP | Advance ledger | Workflow B | **Interface** (WF-defined contract, synchronous, in the pay transaction) | Medium — characterized (`spec/characterization/workforce/advance_payment_spec.rb`) |
| 3 | **Resolved (Pilot 10 M4, on the pilot branch).** Was: `Requests::PunchCorrectionApplier` updated `AttendanceRecord` (+ payroll via AP service); now it calls the WF contract `Requests::PunchCorrectionEffects.correction_approved`, implemented by AP (`Attendance::PunchCorrectionEffects`), and persists the returned snapshot | AP | Correction changes punches and pay | Workflow C | **Interface** (WF-defined contract, synchronous, in the approve transaction) | High — characterized (M1, M4-1); see `next-pilot-selection.md` §25 |
| 4 | **Resolved (permissions: Pilot 9; punch corrections: Pilot 10 M4).** Late / early-leave approval and cancellation go through `Requests::PermissionPayrollEffects` (`Payroll::PermissionPayrollEffects` → `PermissionApplier` / `PermissionReverter`); punch-correction cancellation goes through `Requests::PunchCorrectionEffects.correction_cancelled` (`Attendance::PunchCorrectionEffects`). The canceller's pre-M4 punch rollback methods were deleted in Pilot 10 M6 | AP | Undo permission / punch effects | Workflow C | **Interface** (WF-defined contract, synchronous, in the cancel transaction) | High — characterize first |
| 5 | **Resolved (Pilot 8).** Was: `Employee::InsuranceProfileUpdater` triggers `Payroll::EntryRecalculator`; now it calls the WF contract `Employee::InsuranceProfileEffects.profile_changed`, implemented by AP (`Payroll::InsuranceProfileEffects`) | AP | Insurance affects open entries | AP reacts | **Interface** (WF-defined contract, synchronous after commit) | Low–medium |
| 6 | Goods receipt approval/settlement/void call `FinancialSettlementService`; custody accounts chosen as funding | FS | Paying suppliers | Workflow D | **Event** `goods_receipt.*` + FS-owned settlement UI | Medium–high — today transactional with the receipt. **Goods-receipt writes resolved (Batch S, §38 of `next-pilot-selection.md`):** through the IP-defined `Inventory::GoodsReceiptPaymentEffects`, FS implementation, synchronous inside the receipt transaction (the event target deferred, approved 2026-10-21). Purchase Request advance deposits / reversals **resolved (S2, §39)** through the IP-defined `Inventory::PurchaseRequestAdvanceEffects`, FS implementation |
| 7 | `admin/users` form and onboarding approval write account fields (`email`, `phone_number`, `active`, `permission_role_id`) together with employee fields | OA (account columns) | One combined form; onboarding creates the record | WF edits employee fields; account fields via OA interface | **Interface** (`create_account_for`, `assign_role`, `deactivate`) | Medium — central table and form |
| 8 | **Resolved (Pilot 12).** Was: `admin/branches` form writes `pos_terminals` (nested attributes); now the branch form stages terminal rows through the OA contract `OrganizationAccess::BranchTerminalSettings`, implemented by FS (`Finance::BranchPosTerminals`), and the branch's own save persists them (markup, parameters and validation unchanged) | FS | Terminals are edited on the branch form | FS owns terminal editing (UI stays embedded) | **Interface** (OA-defined contract, synchronous, in the branch save) | Low |
| 9 | **Resolved for the shift form (Milestone 2, Pilot 4).** Was: Shift form wrote `penalty_rules` through nested attributes; now it stages rows through the WF `Shifts::PenaltyRuleSettings` contract (AP implementation). `admin/penalty_rules` and `api/v1/penalty_rules` are AP controllers | AP | Penalty rules configured per shift | AP owns penalty-rule editing (UI may stay embedded) | **Interface** | Low–medium (API paths stay as they are) |
| 10 | **Resolved (Batch W).** Was: `admin/users` assigns `assigned_warehouse_ids` (`WarehouseAssignment`) directly; now the employee form applies the submitted set through the OA contract `OrganizationAccess::UserWarehouseAccess`, implemented by IP (`Inventory::UserWarehouseAssignments`). Behaviour unchanged, including the timing (immediate for a persisted user — not atomic with the rest of the form, TD-W-1) and the fail-open read rule `User#inventory_warehouse_ids` | IP | Warehouse access set on the user form | IP owns warehouse-access editing (UI stays embedded) | **Interface** (OA-defined contract) | Low |
| 11 | Attendance services call `Payroll::DraftRegenerator` | AP | Keep drafts current | Internal to AP | Internal event | Low |
| 12 | `Finance::PosImports::ExpenseGenerator` creates fee expenses | FS | Card fees | Internal to FS | Internal | Low |
| 13 | `Laundry::BatchMaterialConsumer` inserts `InventoryMovement` | IP | Laundry consumes stock | Internal to IP | Internal `post_consumption` | Low–medium |

## 15. Shared Kernel

Extremely small: primitives and contracts only. **No business models or business services.**

| Candidate | Classification | Reason |
|---|---|---|
| Record IDs and the `business_id` tenancy convention | **Shared kernel** (convention) | Every record is business-scoped |
| `BusinessDay` (date/time primitive) | **Shared kernel** | "Today for this business"; used by AP, FS, IP, WF |
| Money/currency value & formatting (`format_currency`) | **Shared kernel** | All domains present money in the business currency |
| Service `Result` contract (unify `ok?`/`success?`) | **Shared kernel** | Minimal cross-domain contract |
| `Voidable`, `ImmutableDocument` (behaviour contracts) | **Shared kernel** | Immutability invariant shared by FS and IP; no data |
| Domain-event contract (name + payload conventions) | **Shared kernel** (future, definition only) | Needed by §14 workflows |
| `AuditLog`, `AuditLoggable` | **Infrastructure** | Cross-domain audit store/mechanism |
| `Attachable` | **Infrastructure** | Active Storage validation |
| `ApplicationPolicy` (mechanism) | **Infrastructure** | Pundit plumbing; rules belong to OA/domains |
| `Api::*` API foundation | **Infrastructure** | Transport |
| `WorkspaceHelper`, layouts, shared partials | **Infrastructure** (UI shell) | Navigation/presentation |
| `EmployeeScope`, `BranchScope`, `Approvals::SelfApproval` | **Organization & Access** | Access / segregation-of-duties rules |
| `BranchMembership` | **Workforce** | Derived from shift assignments (implements OA's membership contract) |
| `Settleable`, `FinancialSettlementService` | **Finance & Sales** | Settlement rules |
| `Geo::Haversine` | **Attendance & Payroll** | Only consumer is geofencing |
| `Business`, `Branch`, `User` | **Organization & Access** | Business models — never shared kernel |

## 16. Infrastructure

| Concern | Current implementation |
|---|---|
| Authentication | Devise (session cookie), Warden; device tokens for biometric devices |
| Authorization mechanism | Pundit, `ApplicationPolicy`, scope helpers (rules from OA and each domain's policies) |
| API foundation | `Api::V1::BaseController`, `Api::*` concerns, `Api::ListQuery`, `Api::Errors`, serializers base, rate-limit store |
| Logging / tracing | Structured API request log, `request_id`, parameter filtering |
| Audit | `AuditLog` / `AuditLoggable` |
| Background jobs | Solid Queue, `ApplicationJob`, `config/recurring.yml` (domain jobs belong to AP and FS) |
| Domain-event dispatch (future) | In-process publisher/subscriber with transactional handlers or outbox — infrastructure, not a domain |
| Caching | Solid Cache |
| File storage | Active Storage → Cloudflare R2 |
| Import/export plumbing | `roo`/CSV readers, `caxlsx`, Grover PDF renderers (parsing/mapping rules stay in domains) |
| Notifications | None active (legacy table, §20); future infrastructure, never a business domain |
| External integrations | No outbound HTTP; inbound device punches and imported files |
| i18n / RTL | `config/locales/*` |
| UI shell | Layouts, sidebar/workspaces, shared partials, Stimulus |
| Database | PostgreSQL, single schema, row-level `business_id` |

## 17. API Mapping

| Endpoint | Domain | Mixed? |
|---|---|---|
| `POST /api/v1/auth/login`, `DELETE /api/v1/auth/logout` | OA | **Yes** — payload includes `checkin_branch_ids` (WF) and `can_check_in` (AP flag) |
| `/api/v1/shifts…`, `/api/v1/shift_assignments…` | WF | — |
| `/api/v1/shifts/:shift_id/penalty_rules…` | **AP** (penalty rules) | Path nested under a WF resource |
| `/api/v1/employee_requests…` | WF | **Yes** — approve/cancel currently write AP data (§14) |
| `/api/v1/attendance/check_in|check_out|today`, `/api/v1/attendance/punch` | AP | Reads WF (current assignment) |
| `/api/v1/attendance_records…`, `/api/v1/reports/attendance` | AP | Report uses OA `BranchScope` |
| `/api/v1/advances…` | AP | — |
| `/api/v1/users/:user_id/salary_profiles…` | AP | Path nested under an OA resource |
| `/api/v1/payroll_periods…`, `payroll_entries…`, `payroll_adjustments…`, `payroll_line_items…`, `/api/v1/reports/payroll/*` | AP | — |
| `/api/v1/businesses`, `/branches`, `/users` (declared, unimplemented) | OA | — |

No API exists for Inventory & Purchasing, Finance & Sales, Reporting, or Workforce employee management/performance.
Routes are unchanged by this document.

## 18. Cross-Domain Interaction Rules

1. **Six top-level domains only.** Sub-areas stay internal; a new top-level domain needs a strong, documented reason.
2. **One owner per important model and table** (§10, §11); shared `users` columns follow §3.2 stewardship.
3. **A domain must not directly write to another domain's internal tables.**
4. **To cause a state change in another domain:** call its explicit **public interface**, or **publish a domain event** that the owning domain consumes.
5. **Dependencies point downstream only** (§12.1). Upstream needs are met by contracts the upstream domain defines and the downstream domain implements.
6. **In-process only:** interfaces and events run inside the same Rails modular monolith; no HTTP between domains; no microservices.
7. **Transactional integrity for money and payroll:** handlers for effects that are atomic today run in the same transaction (or via an outbox) and are idempotent.
8. **Business rules live in the owning domain**, never in controllers, helpers, views or other domains. Controllers stay thin: authenticate → authorize → call a domain service → render.
9. **Reporting reads, never owns or writes.** Single-domain reports stay in their domain.
10. **Shared kernel stays minimal** (§15): primitives and contracts only.
11. **Authorization is centralized:** permissions and scopes defined by OA; Pundit mechanism in infrastructure; each domain's policies use them without re-implementing visibility.
12. **Business isolation at every boundary:** interfaces and event handlers resolve records inside the acting business; no request-supplied `business_id` is trusted; each interface gets cross-business specs.
13. **User ≠ Employee:** Workforce never changes account/authentication/authorization data; OA never changes employee profile/employment data.
14. **Scheduling eligibility is decided by Workforce**, not implied by having a User account.
15. **Immutability preserved:** void/reverse/compensating entries only; `log_audit` on every state change.
16. **Business day, timezone, currency** come from `BusinessDay` / OA settings, never `Date.today`.
17. **No new cycles**; the graph in §12.1 stays acyclic.
18. **Moves are mechanical:** relocating files changes no constants, behaviour, schema or routes.

## 19. Migration Sequence

A **dependency order, not a ranking of importance.** Each domain moves after the domains it depends on.
Evidence per domain (spec files / ≈examples / app files changed since 2026-06-01; approximate):
OA 16 / 297 / 124 · WF 61 / 1,103 / 197 · AP 101 / 1,895 / 275 · FS 154 / 1,524 / 839 · IP 116 / 1,108 / 544 · RP 9 / 105 / 83.

| Step | Domain | Why at this point |
|---|---|---|
| 0 | **Shared Kernel / Infrastructure separation** | No behaviour change; dependency checks in report-only mode record every current violation. **Report-only checker implemented** (`script/architecture/dependency_inventory.rb`, `bin/rails architecture:dependency_report` → `docs/architecture/dependency-inventory-report.txt`, proven by `spec/architecture/dependency_inventory_spec.rb`; `next-pilot-selection.md` §40). Enforcement not enabled |
| 1 | **Organization & Access** | Top of the graph; everything depends on it. Define the membership contract. Thin tests → add characterization specs for scopes (security suites exist) |
| 2 | **Workforce** | Depends only on OA. Define `employee_request.*` events and request contracts; establish User ≠ Employee stewardship and scheduling eligibility as a documented responsibility |
| 3 | **Attendance & Payroll** | Depends on OA + WF; strongest tests (≈1,900 examples) and the only characterized API; implements WF contracts; publishes `payroll.period_finalized` |
| 4 | **Finance & Sales** | Consumes AP (and later IP) effects; highest churn and the largest controller (`Finance::DailyReconciliationsController`, 1,865 lines) — slim it as a prerequisite |
| 5 | **Inventory & Purchasing** | Depends on OA; publishes `goods_receipt.*` for FS; FS's settlement workflow for receipts is completed here. Its FS-bound effects can only be switched once FS (step 4) consumes them |
| 6 | **Reporting** | Reads every domain — last; also receives the labour-cost aggregation from the laundry cost report (done ahead of order in Pilot 11) |

Repository evidence does not require changing this sequence. Note on steps 4–5: until step 5, the existing
`FinancialSettlementService` calls from goods receipts remain as recorded violations. *(Since Batch S the goods-receipt
calls go through `Inventory::GoodsReceiptPaymentEffects`, ahead of step 5; the Purchase Request advance calls followed in S2 through `Inventory::PurchaseRequestAdvanceEffects`.)*

Before each step: triage that domain's pre-existing failing specs (docs/api/baseline.md) and add characterization
specs where coverage is thin.

Each component within a step follows the standard procedure in `migration-pattern.md` (derived from the completed
PermissionRole pilot).

## 20. Resolved and Remaining Items

### 20.1 Resolved (repository evidence)

| Item | Domain owner | Status | Evidence | Keep in document? |
|---|---|---|---|---|
| `notifications` table | **Infrastructure** (future notifications) | **Legacy / unused** | Model removed in commit `20c7430` "Remove notification system"; migrations `20260527000002_create_notifications`, `20260530100050_add_notification_framework_columns` remain; no code references; `users.notification_preferences` unused | Yes — as legacy; do not delete now |
| `product_variants` table | **Inventory & Purchasing** | **Legacy / unused** | Model removed in commit `3a70f41`; FK from `product_barcodes.variant_id` remains; `businesses.variant_system_enabled` column exists with no code references | Yes — as legacy |
| `Service` / `services` | **Inventory & Purchasing** (laundry area) | **Inactive stub** | Only `Business has_many :services`; no controller, route, policy or UI; `expected_towel_usage` referenced only by the model | Yes — flagged inactive; a real service catalogue would be a future decision |
| `BranchRevenue` / `branch_revenues` | **Finance & Sales** | **Legacy / unused as a revenue source** | `Finance::DashboardController` comments and `spec/requests/finance/dashboard_spec.rb` / `spec/services/finance/reports/branch_profitability_spec.rb` state revenue now comes from verified daily reconciliations and a manual `BranchRevenue` row must **not** be used; no create path in `app/` | Yes — as legacy |
| `admin/users` | **Workforce** (employee management) with **OA** actions | **Active, mixed** | Actions: index/new/create/show/edit/update/destroy (employee profile — WF), `toggle_active` (account status — OA), `transfer_ownership` (business ownership — OA); `user_params` mixes account fields (`email`, `phone_number`, `active`, `permission_role_id`), employee fields and `assigned_warehouse_ids` (IP) | Yes — split responsibilities documented (§14.2 #7, #10) |
| Business settings on `businesses` | **OA** owns storage; each domain owns the meaning | **Active** | AP: `payroll_auto_generate_day`, `payroll_cutoff_day`, `working_days_per_month`, `max_salary_advance_percentage`, `overtime_grace_minutes`, attendance duration thresholds (`settings` JSON); WF: `employee_code_start`; IP: `barcode_prefix`, `barcode_next_number`; FS: finance thresholds (`settings` JSON); legacy: `variant_system_enabled` | Yes — future `settings_for(business, domain)` accessor; no schema change |
| User vs Employee | OA (User) / WF (Employee) | Decided | §3 | — |
| `EmployeeInsuranceProfile`, `Department`, `JobTitle` | WF | Decided | §10.1 | — |
| `PenaltyRule`, `Geo::Haversine`, `Advance`, `Employee::PerformanceScorer` | AP | Decided | §10.1 | — |
| `WarehouseAssignment` | IP | Decided | §10.1 | — |
| `PaymentMethod`, `FinancialAdjustment` | FS | Decided | §10.1 | — |

### 20.2 Remaining (minor, need confirmation — no evidence of contradiction)

| Item | Question |
|---|---|
| "EmployeeUserProfile" | No model with this name exists. Confirm it refers to the Employee profile columns on `users` and/or `EmployeeInsuranceProfile` (both documented as Workforce) |
| Login identifiers as contact data | `email` / `phone_number` are both login identifiers (OA) and employee contact details (WF). Documented as OA-stewarded, readable by WF — confirm |
| Attendance-channel flags on `users` | `allow_mobile_attendance` / `allow_biometric_attendance` documented as AP-stewarded — confirm (alternative: WF scheduling/eligibility) |
| Duplicated PDF renderers | Finance dashboard and Performance each wrap Grover — confirm as shared infrastructure |
| Unmapped specs | ≈12 cross-cutting spec files (permission matrix, navigation, sidebar) to be assigned during step 0 |

## 21. Future Extensibility

Booking is not designed here. The six-domain architecture can later accommodate a **Booking** domain as an
additional downstream domain without restructuring the existing six:

* It would consume **Organization & Access** (business, branches, business day/timezone, accounts and permissions)
  and **Workforce** (Employees and their scheduling eligibility/assignments as availability input) — which is why
  scheduling eligibility and User ≠ Employee are established now.
* It would publish its own financial effects for **Finance & Sales** in the same way as payroll and purchasing
  (event → FS records), and be read by **Reporting**.
* No existing domain would depend on it. Future prerequisites (a service catalogue — today `Service` is an inactive
  laundry stub — and customer identity separate from `users`) belong to that future phase.

## 22. Risks

| Risk | Impact | Mitigation |
|---|---|---|
| User/Employee share one table | Stewardship rules can be bypassed by combined forms (`admin/users`) | Document stewardship (§3.2); split form responsibilities during WF migration; no schema change in this plan |
| Authorization depends on Workforce data | Membership changes alter visibility | Membership contract with dedicated specs; security suites as gates |
| Event-based money/payroll effects | Lost or duplicated expenses/advances if handlers run outside the triggering transaction | Transactional handlers or outbox; idempotency keys/indexes (existing partial unique index for insurance expenses) |
| Requests ↔ payroll/attendance conversion | High-risk snapshot/restore logic (`Requests::Canceller` 287 lines, `PunchCorrectionApplier`) | Characterization specs before conversion — done for permissions (Pilot 9) and punch corrections (Pilot 10 M1 / M4-1; remaining concurrency risks in `next-pilot-selection.md` §25.10.2) |
| Goods-receipt settlement inversion | Settlement is transactional with receipt approval today | Transactional event handling; keep `FinancialSettlementService` as FS's internal implementation |
| Scheduling eligibility undefined today | Owners/admins selectable in shift workflows | Documented as a WF responsibility; behaviour change needs its own approval |
| Large domains (AP 72 services, FS 85, IP 69) | Big, conflict-prone moves | Mechanical, per-area batches; quiet windows |
| High churn in FS and IP | Merge conflicts | Schedule moves between feature releases |
| Oversized controllers (`DailyReconciliationsController` 1,865 lines, `PayrollPeriodsController` 516) | Cross-domain logic travels with the move | Slim first |
| Central permission catalogue | Every domain edits `PermissionRole` | Registration producing an identical catalogue, verified by spec |
| Pre-existing failing specs (≈95) | Moves judged against a red baseline | Triage per domain before each step |
| Legacy tables/columns kept | Confusion about what is live | Marked legacy in §20; removal only via a separate, approved change |
