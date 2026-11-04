# Floating Employees, Working Schedules, Payroll Entitlement & Salary Advances — Implementation Plan

**Status:** **APPROVED DESIGN — NOT IMPLEMENTED BEYOND PHASE 1 SCOPE.** No phase is authorised; every phase
needs explicit owner authorisation (§15). The Floating Employees implementation itself (phase 1 scope) exists as
uncommitted work on `feat/floating-employees` and is **not yet authorised for commit**.

**Single source of truth** for this work. It consolidates the approved decisions reached in review (Nov 2026). It
does not restate the architecture rules — it references them:

* `docs/architecture/module-boundaries.md` — domains, allowed dependency graph, contracts (the 2026-11-04
  floating-employees note in §14.1 A).
* `docs/architecture/migration-pattern.md` — testing, database and commit standards.
* `docs/architecture/dependency-exceptions.md` and `docs/architecture/dependency-inventory-report.txt` — the
  dependency gate and its generated report.
* `docs/attendance_flow.md` (§3c cross-branch biometric attendance), `docs/payroll_flow.md`,
  `docs/finance_module.md` — current behaviour of the touched flows.
* `docs/deployment_checklist.md`, `docs/rollback_strategy.md` — standard deployment and rollback procedure.
* `docs/quality/deferred-bugs.md` — deferred bugs (BUG-044, device admin audit logging, is related but out of scope).

---

## 1. Approved decisions

### 1.1 Already implemented (uncommitted, phase 1 scope)

* **Floating assignments.** `ShiftAssignment` kind `floating` (string enum, no migration): no branch, never
  overlapping any other assignment of the employee; branch required for `regular` and `temporary_coverage`.
  BUG-031 tenant backstop uses the employee's business when there is no branch. `Shifts::Assigner` closes open
  regular/floating assignments when switching to floating. Web creation of floating assignments only for
  business-scope assigners. Floating employees punch at any active device of their business; each punch keeps its
  actual branch (`biometric_punch_logs.branch_id`, PR #110); one attendance record per work date with a NULL branch.
* **Time calculation.** `Attendance::TimeCalculator` takes the business (time zone), not the branch.
* **Central payroll review.** One central review slot (`payroll_period_branch_reviews.branch_id` NULL,
  `reviewer_id` NULL until acted on) per period with floating employees; completed or sent back only by
  business-scope `complete_branch_review` holders (`PayrollPeriodBranchReview.central_reviewer?`); mandatory before
  finalization, the under_review override included. `Payroll::CentralReview` derives "current" from a fingerprint
  of the reviewed floating payroll content, (re)opens the slot when floating employees appear or their payroll
  changes (sending a branch-review-completed period back to under_review) and is synced under the period lock before
  every finalization. Every slot completion writes `review_slot_completed`; reopening writes
  `central_review_reopened`. On resubmission a slot's reviewer returns to its branch manager (central: none).
* **Unallocated costs.** Floating employees' employer insurance is a separate payroll-generated business-level
  Expense (`expenses.unallocated`, no branch, no split, check constraint `expenses_unallocated_payroll_only`;
  partial unique index on `(source_payroll_period_id, unallocated)`); `Payroll::FinalizationEffects.period_finalized`
  carries `employer_insurance_unallocated:`. Floating salaries and unallocated expenses appear on an explicit
  Unallocated line (`Finance::Reports::Table#unallocated`) counted once in business-wide totals, never in a branch
  row; branch-filtered dashboard views exclude them; the floating salary is shown only with business-wide
  `view_payroll` (`Finance::PayrollCostAccess#unallocated?`). Payroll UI labels: Floating (employee) / Unallocated
  (cost).
* **Attribution across a mid-period assignment change:** the last assignment of the period decides the whole
  period's salary and employer insurance — no proration.

### 1.2 Approved for implementation (phases 4–14)

* **Commit boundary:** one commit for the 80-file Floating Employees scope (§2) — message
  `feat: floating employees — assignments, central payroll review, unallocated costs`. **Not yet authorised.**
* **P9 — resolver:** existing `Shifts::AssignmentResolver` resolves one winning assignment per date: temporary
  coverage first, then latest `effective_from`, then highest id. Weekdays read only from the winner — never unioned
  from losing assignments. No competing resolver; precedence unchanged. Other paths are follow-ups (§10).
* **P10 — templates:** multi-select weekday picker on template entries, persisted as **one `ShiftTemplateEntry` per
  selected weekday** in the existing single `weekday` column (no schema change). Grouping key
  `shift_id + starts_on + effective_ends_on + shift_rule_profile_id + employee_role`, per employee; union of explicit
  weekdays; all-empty → NULL; mixed explicit/empty → union + preview warning; a range containing none of its weekdays
  → preview warning; weekdays copied at creation, never live-linked; existing date and conflict behaviour preserved.
* **Locked payroll — strategy A:** never change an assignment's schedule in place when it overlaps a finalized or
  paid period; end it and create a successor from a change date after the last locked period's end, atomically —
  also when first defining a NULL schedule. Attendance records stay linked to the old assignment.
* **Mixed-schedule month — hybrid:** per date and per assignment: defined dates use the schedule rule; undefined
  dates use the legacy rule; NULL never implies rest days.
* **Attendance requirement:** `users.requires_attendance` nullable (true required / false exempt / NULL not
  reviewed = legacy behaviour); migration sequence in §6; no backfill; three-state UI.
* **Payroll behaviour:** matrix in §7 (P11: scheduled monthly required absence only on elapsed scheduled days; P12:
  daily required pays every complete day, rest days included; daily exempt with schedule pays scheduled days
  without punches; daily exempt without schedule earns 0 + warning). No holiday calendar in this scope.
* **Salary advances P1–P8:**
  * **P1** revalidate under the new rule at approval and payment; read-only preview of affected pending and
    approved-but-unpaid requests first; never bulk-cancel, amend or pay.
  * **P2** attendance penalties reduce entitlement (required employees only; exempt have none).
  * **P3** overtime excluded from entitlement.
  * **P4** reservation semantics in §8.6.
  * **P5** reservation month = business month of `requested_for_date`, for requests and their advances.
  * **P6** revalidation failure writes `advance_limit_recheck_failed`; no duplicate salary-view record.
  * **P7** `BusinessDay` for all boundaries; legacy undefined dates: proration rounded down; today counts only when
    complete; scheduled dates: exact counts.
  * **P8** only requests whose `requested_for_date` falls in the **current business month** are accepted; past and
    future business months are rejected.
* **No request editing:** a request failing revalidation is rejected or cancelled through the existing workflow and
  the employee submits a new, lower request.
* **Bulk payment lock order:** all employee-and-month locks first, sorted by (user_id, month), then request rows by
  ascending id.
* **Mobile API:** approval/payment through the same `Requests::Approver` gain revalidation; existing error format;
  no new mobile parameters.
* **`requires_shift_assignment`:** removed in two releases (§12).
* **Dependency inventory:** regenerated in phase 9 (§3).

---

## 2. Git state and the Floating Employees commit manifest

Recorded state (re-verify before use, §15): branch `feat/floating-employees`, HEAD `ce31dde` = `origin/main`;
0 staged, 60 modified, 18 untracked, 0 deleted; diff 60 files, +828 / −209; 3 older stashes. `stash@{1}` and
`stash@{2}` overlap commit files (shift-assignment files, locales, `db/schema.rb`) — **never apply, pop or include
them.** PR #110 is merged (`6988782`) and must not be modified.

**Manifest expanded to 80 paths (owner-approved, 2026-11-04):** the H-1 fix
(`app/views/dashboard/_widget_my_attendance.html.erb`, floating-employee dashboard check-out with a NULL branch) and
its request spec (`spec/requests/dashboard_floating_attendance_spec.rb`) are part of the commit — 61 modified,
19 untracked.

**This plan document is NOT part of the 80-file manifest.** It is an additional untracked file; whether it is
committed with the floating work or separately is a decision for the commit approval (§16).

Modified (61):
```
app/controllers/api/v1/payroll_periods_controller.rb
app/controllers/finance/dashboard_controller.rb
app/controllers/finance/reports_controller.rb
app/controllers/payroll_dashboard_controller.rb
app/controllers/payroll_periods_controller.rb
app/controllers/shift_assignments_controller.rb
app/helpers/shift_assignment_helper.rb
app/javascript/controllers/assignment_kind_fields_controller.js
app/models/finance_sales/expense.rb
app/models/payroll_audit_log.rb
app/models/payroll_period_branch_review.rb
app/models/shift_assignment.rb
app/policies/payroll_period_policy.rb
app/services/attendance/derived_fields.rb
app/services/attendance/record_recomputer.rb
app/services/attendance/time_calculator.rb
app/services/finance/payroll_cost_access.rb
app/services/finance/payroll_finalization_effects.rb
app/services/finance/payroll_insurance_expense.rb
app/services/finance/reports/branch_profitability.rb
app/services/finance/reports/csv_exporter.rb
app/services/finance/reports/expense_details.rb
app/services/finance/reports/expense_sources.rb
app/services/finance/reports/expense_summary.rb
app/services/finance/reports/table.rb
app/services/payroll/approver.rb
app/services/payroll/branch_review_completer.rb
app/services/payroll/changes_requester.rb
app/services/payroll/employer_insurance_cost.rb
app/services/payroll/finalization_effects.rb
app/services/payroll/insights_presenter.rb
app/services/payroll/overtime_recalculator.rb
app/services/payroll/period_recalculator.rb
app/services/payroll/recommendation_engine.rb
app/services/payroll/submit_for_review.rb
app/services/shifts/assigner.rb
app/views/admin/attendance_records/show.html.erb
app/views/admin/users/_shift_timeline.html.erb
app/views/attendance_records/edit.html.erb
app/views/attendance_records/index.html.erb
app/views/attendance_records/show.html.erb
app/views/dashboard/_widget_my_attendance.html.erb
app/views/finance/expenses/index.html.erb
app/views/finance/expenses/show.html.erb
app/views/finance/reports/_table.html.erb
app/views/payroll_periods/_activity_timeline.html.erb
app/views/payroll_periods/show.html.erb
app/views/shift_assignments/_form.html.erb
app/views/shift_assignments/confirm_delete.html.erb
app/views/shift_assignments/confirm_end.html.erb
app/views/shift_assignments/index.html.erb
config/locales/ar.yml
config/locales/en.yml
db/schema.rb
docs/architecture/module-boundaries.md
spec/factories/payroll_period_branch_reviews.rb
spec/factories/shift_assignments.rb
spec/services/attendance/time_calculator_spec.rb
spec/services/payroll/finalization_effects_routing_spec.rb
spec/services/payroll/finalization_effects_spec.rb
spec/services/payroll/period_recalculator_spec.rb
```

Untracked (19):
```
app/services/payroll/central_review.rb
db/migrate/20261104190000_allow_central_payroll_period_review.rb
db/migrate/20261104200000_add_unallocated_to_expenses.rb
spec/models/expense_unallocated_spec.rb
spec/models/shift_assignment_floating_spec.rb
spec/policies/floating_employee_visibility_spec.rb
spec/requests/api/v1/floating_punch_spec.rb
spec/requests/attendance_records_floating_spec.rb
spec/requests/dashboard_floating_attendance_spec.rb
spec/requests/finance/dashboard_unallocated_spec.rb
spec/requests/payroll_central_review_spec.rb
spec/requests/shift_assignments_floating_spec.rb
spec/services/attendance/floating_attendance_spec.rb
spec/services/finance/reports/unallocated_attribution_spec.rb
spec/services/payroll/assignment_transition_attribution_spec.rb
spec/services/payroll/central_review_lifecycle_spec.rb
spec/services/payroll/central_review_spec.rb
spec/services/payroll/unallocated_insurance_spec.rb
spec/services/reports/attendance_summary_floating_spec.rb
```

Both migrations are applied on the **test database only**. The last full focused verification (7,996 examples,
0 failures; architecture, RuboCop, Zeitwerk, `git diff --check` clean) predates this document and **must be re-run**
before the commit (§15).

---

## 3. Architecture and dependencies

```
Workforce (WF)                              Attendance & Payroll (AP)                    Finance & Sales (FS)
ShiftAssignment.working_weekdays ─────┐
ShiftTemplateEntry.weekday (1/row)    │
Admin::ShiftTemplatesController       │
  (multi-select → one row per weekday)│
Scheduling::TemplatePreviewer /       │
  TemplateApplier (group → 1 assignment)
Shifts::ScheduleChanger (end+successor)
Shifts::AssignmentResolver            │
  .for / .for_dates (read) ◀──────────┼── Payroll::ScheduledDays (read)
Requests::Submitter / Approver /      │       │
  BulkPaymentService                  │       ▼
  └─ Requests::AdvanceLimitCheck ─────┼─▶ Requests::RequestFormReads (WF-defined contract)
     (employee–month lock → request)  │       └─ Payroll::RequestFormReads (AP impl)
                                      │             └─ Salary::AdvanceEligibilityCalculator
                                      │                   ├─ Payroll::EarnedEntitlement (read-only)
                                      │                   │     └─ Payroll::PricingCore (pure) ◀── Payroll::EntryCalculator (persists; output unchanged)
                                      │                   └─ salary-advance reservation base (§8.6)
                                      └── existing AP→WF read edge only                      Payroll::EmployerInsuranceCost ─▶ FinalizationEffects ─▶ FS
```

* Only existing dependency directions are used. The single contract change is `Requests::RequestFormReads#advance_limit`
  gaining `as_of:` and `excluding_request_id:` (WF-defined, AP-implemented).
* **Dependency inventory (approved):** in phase 9, after the new Payroll services exist, regenerate
  `docs/architecture/dependency-inventory-report.txt` from the implemented code
  (`bin/rails architecture:dependency_report`), review the diff for legitimate dependency changes only, and run
  `bundle exec rspec spec/architecture`.

---

## 4–5. Implementation phases and files

| # | Phase | Main files | Depends on |
|---|---|---|---|
| 1 | Final verification (§15) and owner-approved single commit of the floating work | the 80-file manifest | owner approval |
| 2 | Open the Floating Employees PR — **no merge** without separate approval | — | 1 |
| 3 | **Production NULL-branch pre-deployment query** (§15.3), read-only, by an authorised operator | — | before deploying 1 |
| 4 | **Working weekdays:** schema, model, Assign Shift picker, schedule editing, `Shifts::ScheduleChanger` (end + successor) | migration; `shift_assignment.rb`; `shift_assignments_controller.rb`; `_form`/`edit`; `assignment_kind_fields_controller.js`; `shifts/assigner.rb` (optional parameter); bulk assign; new `shifts/schedule_changer.rb`; `shift_assignment_policy.rb`; locales | 1 |
| 5 | **Template weekday multi-select and grouping** | `shift_template_entry.rb`; `admin/shift_templates_controller.rb` (permit `weekdays[]`, expand to rows); template form; `scheduling/template_previewer.rb`; `template_applier.rb`; `conflict_detector.rb` call site; locales — **no schema change** | 4; production template-entry check (§9) |
| 6 | **Missing-schedule report** and HR schedule review (§11) | `shift_assignments_controller#schedule_review`; `shift_assignment_policy.rb`; view; CSV; route | 4 |
| 7 | **`requires_attendance` + payroll exemption behaviour** | migration (§6); `user.rb`; `user_policy.rb`; `admin/users/_form` (three-state); `organization_access/accounts.rb`; `employee_data_requests/employee_attributes.rb`; `payroll/entry_calculator.rb`, `basic_salary_calculator.rb` (via phase 8–9 helpers); `payroll/anomaly_detector.rb`; period page (exempt count + list); `dashboard/owner_data.rb`, `area_manager_data.rb`; locales | 4, 6 |
| 8 | **Resolver extension + `Payroll::ScheduledDays`** | `shifts/assignment_resolver.rb` (`for_dates`); new `payroll/scheduled_days.rb` | 4 |
| 9 | **Pure pricing + `Payroll::EarnedEntitlement`** | new `payroll/pricing_core.rb`; `entry_calculator.rb` (delegates, output unchanged); new `payroll/earned_entitlement.rb`; **`docs/architecture/dependency-inventory-report.txt`** (regenerated and reviewed) | 8 |
| 10 | **Read-only advance preview and rollout checks** (owner only): current vs new limit per employee; affected pending and approved-but-unpaid requests (P1); the §8.6 anomaly queries | `lib/tasks/advances.rake` | 9 |
| 11 | **Advance limit at creation; P8 date rule; P4 reservation (§8.6)** | `salary/advance_eligibility_calculator.rb`; new shared salary-advance reservation scope/query object (§8.6); `payroll/request_form_reads.rb`; `requests/request_form_reads.rb` (contract); `employee_request.rb`; `requests/submitter.rb` (lock); request form view | 9, 10 + owner review of the preview |
| 12 | **Approval/payment revalidation + concurrency lock** | `requests/approver.rb`; `requests/bulk_payment_service.rb`; new `requests/advance_limit_check.rb` | 11 |
| 13 | **Unallocated salary/insurance for employees without assignments** — remove the first-sales-branch (`ExpenseSources#fallback_branch_id`) and first-branch (`EmployerInsuranceCost`) fallbacks | `expense_sources.rb`; `employer_insurance_cost.rb`; payroll dashboard / recommendation labels | 1 (may move up to directly after 2) |
| 14 | **Remove `requires_shift_assignment` in two releases** (§12) | R1: `admin/users/_form`, `user_policy.rb`, `assignment_eligibility.rb`, `user.rb` (`ignored_columns`), specs. R2: migration only | 7 |

Ordering rationale: 7 needs 4 and 6 so exempt daily employees have schedules before they are paid by schedule; 9
needs 8; 11–12 need 9–10 and the owner's review of the preview; 13 depends only on 1; 14 follows 7 so the export of
`requires_shift_assignment = false` users can inform the attendance review.

---

## 6. Database changes and rollback

| Change | Migration | Verification | Rollback |
|---|---|---|---|
| `shift_assignments.working_weekdays` (phase 4) | `add_column :shift_assignments, :working_weekdays, :smallint, array: true` — nullable, no default, no backfill — plus check constraint `working_weekdays IS NULL OR (cardinality(working_weekdays) BETWEEN 1 AND 7 AND working_weekdays <@ ARRAY[0,1,2,3,4,5,6]::smallint[])`. Sunday = 0 (Ruby `Date#wday`). Model normalises to sorted unique values; empty selection stored as NULL | constraint spec (writes bypassing validations); existing rows stay NULL | code-only after deploy; dropping the column loses entered schedules |
| `users.requires_attendance` (phase 7) | **Two ordered steps, never a single add-with-default:** (1) `add_column :users, :requires_attendance, :boolean` with **no default and no backfill** → every existing row is NULL; (2) **then** `change_column_default :users, :requires_attendance, from: nil, to: true` → only rows inserted afterwards default to true | migration spec: existing rows remain NULL; a new row without a value gets true; production read-only NULL count after deploy equals the employee count before | `down`: (1) `change_column_default … from: true, to: nil`, (2) `remove_column` — loses reviewed values, so export `(id, requires_attendance)` first or roll back code only |
| `requires_shift_assignment` Release 2 (phase 14) | `remove_column :users, :requires_shift_assignment` | Release 1 deployed and verified; no code references remain | re-add the column; restore values from the Release 1 export |

Already applied on the test database only (phase 1 scope): `20261104190000_allow_central_payroll_period_review`
(review `branch_id`/`reviewer_id` nullable; one central slot per period) and `20261104200000_add_unallocated_to_expenses`
(`expenses.unallocated`, check constraint, unique index on `(source_payroll_period_id, unallocated)`). Both are
code-rollback-only once central slots or unallocated expenses exist (see each migration's header).

**Three-state attendance UI:** Required / Exempt / Not reviewed (EN + AR). "Not reviewed" is offered only for an
existing employee whose value is NULL; unrelated edits resubmit the current value so NULL never changes silently;
new employees start Required via the database default.

**Employee creation paths** to cover: admin create (`OrganizationAccess::Accounts.build`), employee data request
approval (`EmployeeDataRequests::EmployeeAttributes` — must not send `nil`), seeds, and any sign-up / invitation path
(enumerate at implementation). No employee CSV import exists today; if one is found it gets the same test.

The P4 reservation needs no migration (§8.6).

---

## 7. Payroll calculation matrix

Window: business-month start → `as_of`; each day priced with the salary profile in force that day (salary profile
segments and effective dates respected); attendance records selected by `work_date`; complete attendance = check-in
and check-out, not absent; each date resolved by `Payroll::ScheduledDays` (resolver per date) to scheduled / rest /
undefined. `Payroll::EarnedEntitlement` never calls `EntryCalculator.call`, `AdvanceDeductor`, `ObligationDeductor`,
adjustments or any write path.

| Employee | Base | Absence | Penalties (P2) | Overtime (P3) |
|---|---|---|---|---|
| Monthly required — scheduled dates | calendar rule | elapsed scheduled days without complete attendance × weighted monthly daily rate | yes | excluded from entitlement; payroll unchanged |
| Monthly required — undefined dates (legacy) / `requires_attendance` NULL | calendar rule | floor(working days × undefined calendar days ÷ period days) − complete days on those dates | yes | same |
| Monthly exempt | calendar rule | none | none | — |
| Daily required / NULL | rate × complete days, rest days included (P12) | — | yes | same |
| Daily exempt — scheduled dates | rate × scheduled days; attendance not read | none | none | — |
| Daily exempt — undefined dates | 0 + **danger** warning | — | — | — |
| No assignment | legacy (monthly: calendar base without absence; daily: complete days) + administrative **warning** | — | per record | — |
| Floating | own floating assignment schedule; attendance from any permitted branch; costs Unallocated | per type | per type | — |

Worked mixed-month example (November 2026; 26 working days; monthly 6,000, daily 250; days 1–14 undefined, then
Sunday–Thursday): monthly required payroll **5,538.46**; daily exempt payroll **3,000**; advance entitlement as of
Nov 20: monthly **3,769.23**, daily exempt **1,250**.

Warnings (payroll anomalies, period page, missing-schedule report): danger — exempt daily without schedule; info —
required on legacy rule for undefined dates; warning — no assignment.

Parity: at `as_of` = period end, `PricingCore` reproduces today's payroll exactly for every case except the approved
changes (exempt daily employees and scheduled-day absence for monthly required employees).

---

## 8. Salary advance lifecycle and locking

**Accepted dates (P8).** `requested_for_date` must fall within the **current business month**
(`BusinessDay.current(context: business)`); past and future business months are rejected at creation. A missing or
invalid date fails the existing presence validation — it is never silently moved to another month. Consequently the
entitlement window ends at the earlier of the current business date and `requested_for_date`, and the reservation
month equals the current business month.

### 8.1 Form
The limit is read through the contract; the salary view is recorded as today.

### 8.2 Creation — `Requests::Submitter`
One transaction: employee-and-business-month lock
`pg_advisory_xact_lock(hashtext('adv:' || user_id || ':' || yyyymm))` (month of `requested_for_date`) → P8 date
check → limit check with the request excluded from its own reservation.

### 8.3 Approval — `Requests::Approver#approve` (salary advances)
Transaction → employee-and-month lock **first** → `@request.lock!` (inside `locked_state_error`) → revalidation →
update.

### 8.4 Payment — `Requests::Approver#pay`
Transaction → employee-and-month lock → `@request.lock!` → revalidation → `Requests::AdvanceEffects.advance_paid`.

### 8.5 Bulk payment — `Requests::BulkPaymentService`
Acquire every selected request's employee-and-month lock up front, **sorted by (user_id, month)**; then pay in
ascending request id (F-A7). Re-acquiring the same transaction-level advisory lock inside `Approver#pay` does not
block. All month locks therefore precede every request row lock.

### 8.6 Salary advance reservation semantics (latest approved version)

**One shared base**, implemented as **one actual reusable scope / query object** (not the condition duplicated
across services). Every reservation bucket, helper, revalidation path, preview and report goes through it:

```
salary_advance_requests(E, M) =
  EmployeeRequest.where(user_id: E, request_type: "salary_advance")
                 .where(requested_for_date: M.first..M.last)   # M = business month of requested_for_date (P5)
```

| Bucket | Source (from the shared base) | Reserves |
|---|---|---|
| Pending | `status: "pending"`, `id ≠ current request` | `employee_requests.amount` |
| Approved, not yet paid | `status: "approved"`, `id ≠ current request` | `employee_requests.amount` |
| Paid with an Advance row | `status: "paid"` `INNER JOIN advances ON advances.employee_request_id = employee_requests.id` | `advances.total_amount`, regardless of `active` or `fully_repaid` |
| Paid without an Advance row | `status: "paid"` with no matching Advance (`LEFT JOIN … WHERE advances.id IS NULL`) | `employee_requests.amount` — conservative fallback, **reported as an anomaly**, never repaired or modified automatically |
| Rejected / cancelled | — | 0 |

Rules:
* `request_type = 'salary_advance'` applies to every bucket, every query and every stage; no other request type can
  affect salary advance entitlement.
* `remaining_amount` is **never** read for reservations; partial or full repayment never releases entitlement within
  the business month.
* Each paid request is counted **exactly once** — through its Advance, or through the fallback when the Advance row
  is missing — never both.
* The request being evaluated is excluded from every bucket.
* The month is always determined from `requested_for_date` (P5).
* Advances enter **only through the shared request base** — never by their own `user_id` or `issued_at`.
* The same base is used at **creation, approval, payment, bulk payment and the phase-10 preview**.
* **Available** = `max(0, entitlement × percentage − reserved)`. A blank business percentage remains unrestricted; no
  salary profile in force remains 0.

**Database guarantee (verified, read-only):** `advances.employee_request_id` is `NOT NULL`, uniquely indexed, and has
a foreign key to `employee_requests` (`add_foreign_key "advances", "employee_requests"`). An orphan Advance cannot
exist, so no orphan-Advance anomaly query is required. Re-confirm at implementation; if the foreign key were ever
removed, add an orphan query to the preview.

**Read-only anomaly queries (phase 10).** Report only; never fix automatically.
```sql
-- 1. Advances whose original amount differs from their salary-advance request
SELECT a.id, a.employee_request_id, a.total_amount, r.amount
FROM advances a
JOIN employee_requests r ON r.id = a.employee_request_id
WHERE r.request_type = 'salary_advance'
  AND a.total_amount <> r.amount;

-- 2. Paid salary-advance requests without an Advance row
SELECT r.id, r.user_id, r.amount, r.requested_for_date
FROM employee_requests r
LEFT JOIN advances a ON a.employee_request_id = r.id
WHERE r.request_type = 'salary_advance'
  AND r.status = 'paid'
  AND a.id IS NULL;

-- 3. Advances linked to a request that is not a salary advance (expected: none; reported, never counted)
SELECT a.id, a.employee_request_id, r.request_type
FROM advances a
JOIN employee_requests r ON r.id = a.employee_request_id
WHERE r.request_type <> 'salary_advance';
```
The current-versus-new limit preview and the P1 affected-requests list use the same shared base.

**P4 tests (all 12):**
1. A paid advance originally issued for 1,000 and partially repaid to 400 still reserves 1,000.
2. A fully repaid advance (`remaining_amount = 0`, status `fully_repaid`) still reserves its original amount during its
   business month.
3. Repayment between approval and payment of another request does not release entitlement.
4. If `advances.total_amount` differs from the linked request amount, the paid reservation uses `total_amount`.
5. A paid request without an Advance row reserves its request amount and appears in the anomaly preview.
6. A paid request is never counted twice as both a request and an advance.
7. Rejected and cancelled requests reserve nothing; the request being checked is excluded from its own reservation.
8. An October request paid in November reserves its original amount against October.
9. Existing tests that rely on `Advance.active` or `remaining_amount` for reservation are replaced, each documented
   as superseded by approved P4 (reserve the original `total_amount`, never the remaining balance).
10. Non-salary-advance requests (late permission, early leave, punch correction) in every status never affect the
    reservation.
11. Each bucket (pending, approved, paid with Advance, paid without Advance) is checked against a non-salary-advance
    request of the same status; only `request_type = 'salary_advance'` is counted.
12. An Advance whose `employee_request_id` points to a non-salary-advance request is never counted and is listed by
    anomaly query 3. The forced fixture is built **without weakening production validations or database
    constraints** — e.g. creating a valid salary-advance request and its Advance, then changing the request's
    `request_type` with `update_column` inside the test (the foreign key and NOT NULL remain satisfied).

### 8.7 Revalidation failure
Nothing is changed. `log_audit(action: "advance_limit_recheck_failed", auditable: request, metadata: { stage,
business_month, as_of, entitlement, percentage, reserved, available, amount })` maps onto the existing `AuditLog`
fields (values in metadata; no invented columns); written after rolling back to a savepoint so it persists; no
salary-view record. The request is then rejected or cancelled through the existing workflow and the employee submits
a new, lower request (no edit workflow). Salary figures are shown only to viewers allowed to see them.

### 8.8 Rollout preview (P1)
Before enforcement: the phase-10 read-only preview — current vs new limit per employee, affected pending and
approved-but-unpaid requests, and the three §8.6 anomaly queries — reviewed by the owner.

### 8.9 Lock order everywhere
Employee-and-business-month advisory lock → request row lock → existing period / entry locks. Never inverted.

---

## 9. Template weekday multi-select and grouping

* **Form:** each logical template line has a weekday multi-select (EN/AR) beside shift, dates and rule profile.
* **Persistence (`Admin::ShiftTemplatesController`):** a line expands into **one `ShiftTemplateEntry` per selected
  weekday** using the existing single `weekday` column. On edit, rows sharing the grouping key are shown as one line;
  saving diffs weekdays — new weekdays create rows, removed weekdays destroy rows, unchanged rows stay. An **empty
  selection** persists one entry with `weekday` NULL (existing no-weekday behaviour). No schema change.
* **Preview and application:**
```
for each employee:
  groups = entries.group_by { |e| [e.shift_id, e.starts_on, e.effective_ends_on, e.shift_rule_profile_id, e.employee_role] }
  each group →
    weekdays = group.filter_map(&:weekday).uniq.sort.presence           # nil when none explicit
    warnings << :mixed_weekdays  if weekdays && group.any? { _1.weekday.nil? }
    warnings << :no_matching_day if weekdays && (starts_on..ends_on).none? { weekdays.include?(_1.wday) }
    conflict = ConflictDetector.call(user:, shift:, branch:, effective_from: starts_on, effective_to: ends_on)  # once per group
    TemplateApplier creates ONE ShiftAssignment(…, working_weekdays: weekdays, source_template:)   # copied, not linked
```
* Findings that shape the design: entry dates come from `starts_on` / `ends_on` (empty `ends_on` = single day); the
  offset fields are unused; `employee_role` filters nothing (kept in the key as approved); the existing template form
  never saved `weekday`.
* **Production check before phase 5:** count template entries per grouping key and with a weekday set, to show which
  existing templates would be affected (expected: none have a weekday).

---

## 10. P9 follow-up issues (documented, not changed by this work)

1. `Attendance::ManualEntryService` selects an arbitrary active assignment (`ShiftAssignment.active_on(...).find_by`)
   instead of the resolver.
2. `Attendance::CheckInService` (mobile) uses the resolver filtered by the chosen branch, on the server date.
3. `Payroll::EntryCalculator#shift_assigned?` checks "any active assignment" on the monthly segment's first day,
   not a per-date resolution.

---

## 11. Missing-schedule report

* `GET /shift_assignments/schedule_review` and `.csv`; policy `schedule_review?` = `view_shifts` or `assign_shifts`.
* Rows: `policy_scope(ShiftAssignment)` intersected with the viewer's `EmployeeScope`; the CSV uses the identical
  query, so it can never expose employees outside the viewer's scope.
* Current and upcoming assignments with `working_weekdays IS NULL`, ordered: exempt daily → exempt monthly → required
  → `requires_attendance` NULL.
* Columns: employee and code, assignment kind, branch or "Floating", shift, dates, salary type (only when the viewer
  may see salary), attendance requirement, edit links (only when authorised).
* Read-only; no automatic updates to employees or assignments. A production version for the owner is a read-only task.

---

## 12. `requires_shift_assignment` — two-release removal

* Current behaviour (audited): the flag only narrows the web Assign Shift picker and its server-side check
  (`Shifts::AssignmentEligibility#shift_based`); it does not affect attendance, payroll, absence, punching, dashboards
  or salary advances.
* **Release 1:** export users with `requires_shift_assignment = false` (id, name, business, current branch) for review;
  remove the checkbox and the permitted attribute; `AssignmentEligibility#shift_based` keeps only the owner exclusion
  and the existing 7-day availability rule — no replacement checkbox; mark the column ignored (`ignored_columns`); the
  column stays.
* **Release 2:** only after Release 1 is deployed and verified and no code references remain — drop the column in a
  separate migration. Never combined with Release 1.

---

## 13. Test matrix and commands

| Area | Coverage |
|---|---|
| Floating employees (regression) | branch-independent attendance; central payroll review lifecycle; unallocated costs; the 13 new floating specs and extended specs |
| Working weekdays | NULL, empty → NULL, invalid, duplicates, 1 and 7 days, database constraint, every assignment kind; `ScheduleChanger`: locked refusal, atomic successor, change date after the locked period, records stay linked, audit; permissions and branch scope |
| Resolver | `for_dates` equals `for` on every date; coverage over regular; latest start; highest-id tie; floating; weekdays only from the winner |
| Templates | multi-select persists one row per weekday; edit diff creates/destroys rows; empty selection → one NULL row; grouping → one assignment with the union; mixed and no-match warnings; role/profile differences; date ranges; template edits don't change created assignments; one conflict check per group |
| Payroll | `PricingCore` parity on all existing entry fixtures; `ScheduledDays`; `EarnedEntitlement` matrix incl. mixed-month figures (§7) and a no-writes check; exempt daily; scheduled monthly absence; P12 rest-day pay; reopened periods reproduce historical payroll |
| `requires_attendance` | old rows stay NULL after migrating; new rows default true; admin create, data-request approval, seeds and any import path; three-state select never changes NULL; exempt excluded from warnings and shown separately; dashboard KPIs |
| Advances P1–P3, P5–P8 | revalidation at creation/approval/payment; self-exclusion; penalties lower the limit; overtime does not raise it; past- and future-business-month requests rejected; business-day start-hour boundary and month rollover; failure audit without salary-view record; reject/cancel then a new lower request; the old "monthly full base" test deliberately replaced with the reason documented |
| Advances P4 | the 12 tests in §8.6 |
| Concurrency | parallel submissions; approval vs payment; overlapping bulk batches with sorted locks |
| Authorization / isolation | missing-schedule report and CSV scope; cross-business requests; branch-manager limits |

Commands (test database only; never concurrently with another DB-sharing run):
```bash
bundle exec rspec spec/architecture
bundle exec rspec <phase-specific specs>
bundle exec rspec spec/services spec/models spec/policies spec/requests
bin/rubocop <changed .rb files>
bin/rails zeitwerk:check
git diff --check
bin/rails architecture:dependency_report   # phase 9 only; review the diff, then re-run spec/architecture
```
Existing tests are never weakened to make new behaviour pass; superseded tests are replaced with the reason recorded.

---

## 14. Risks and mitigations

| Risk | Mitigation |
|---|---|
| Payroll output drifts during the phase-9 extraction | parity spec + full payroll suite; only the approved cases may change |
| Exempt daily employees earn 0 without a schedule | phases 4 and 6 before 7; employees stay NULL until reviewed |
| Bulk payment deadlocks | all month locks first, sorted; then requests by id |
| Monthly advance limits drop | phase-10 preview and owner review before phase 11 |
| Requests dated in another business month | rejected at creation (P8) |
| Repayment releases limit / advance amounts drift / other request types leak in | reserve `advances.total_amount` regardless of status through the single salary-advance base; anomaly queries; P4 tests 1–12 |
| A stash overlapping commit files is applied | never apply `stash@{1}` / `stash@{2}`; stash-content check (§15) |
| Schedule edits don't recalculate payroll automatically | "schedule changed — recalculate payroll" notice on the period page |
| `requires_attendance` defaults by accident | two-step migration; migration spec; post-deploy NULL count |
| Floating-work regressions from later phases | committed first (phase 1); its specs run in every regression pass |

Rollback considerations per change are in §6; standard procedure in `docs/rollback_strategy.md`.

---

## 15. Deployment and verification gates

### 15.1 Before the Floating Employees commit (read-only until the final, approved staging step)
1. Write the §2 manifest (80 paths) to a temporary file outside the repository, e.g. `/tmp/manifest.txt`.
2. Branch is `feat/floating-employees`; HEAD `ce31dde`; base still equals `origin/main`.
3. `git diff --cached --quiet` — zero staged files.
4. Exact path comparison, not counts. The plan document is excluded unless the commit approval includes it:
   `diff <(sort /tmp/manifest.txt) <( (git diff --name-only; git ls-files --others --exclude-standard) | grep -v '^docs/architecture/floating-employees-implementation-plan.md$' | sort )` prints nothing.
5. `test -z "$(git ls-files --deleted)"` — no deletions.
6. `git stash list` shows the same three stashes.
7. Stash-content check: none of each stash's added lines appear in the working diff.
8. PR #110 still merged at `6988782`; branch untouched.
9. `RAILS_ENV=test bin/rails db:migrate:status` — both migrations up (status only).
10. Re-run architecture, focused and regression specs, RuboCop, Zeitwerk and `git diff --check` — do not rely on the
    earlier 7,996/0 result.
11. Only after explicit approval: `git add --pathspec-from-file=/tmp/manifest.txt`, then verify
    `git diff --cached --name-only` equals the manifest exactly.

### 15.2 Every later phase
Owner authorisation; green focused and regression runs; test-database migration status; production read-only checks
where listed; phase 9 — dependency inventory regenerated, reviewed and architecture-checked.

### 15.3 Production read-only checks (authorised operator; no data changes)
* **NULL-branch pre-deployment query** (before deploying the floating work):
  ```sql
  SELECT assignment_kind,
         COUNT(*) AS total,
         COUNT(*) FILTER (WHERE effective_from <= CURRENT_DATE AND (effective_to IS NULL OR effective_to >= CURRENT_DATE)) AS active,
         COUNT(*) FILTER (WHERE effective_from > CURRENT_DATE) AS upcoming,
         COUNT(*) FILTER (WHERE effective_to < CURRENT_DATE) AS ended,
         COUNT(DISTINCT user_id) AS employees
  FROM shift_assignments WHERE branch_id IS NULL GROUP BY assignment_kind;

  SELECT COUNT(*) FROM attendance_records ar
  JOIN shift_assignments sa ON sa.id = ar.shift_assignment_id WHERE sa.branch_id IS NULL;
  ```
* Template entries per grouping key / weekday set (before phase 5).
* Phase-10 advance preview incl. the affected-requests list and the three §8.6 anomaly queries (before phase 11).
* `requires_attendance` NULL count after deploying phase 7.
* Export of `requires_shift_assignment = false` users (before phase 14 Release 1).
* Employee inventory for the attendance review (before any owner-approved classification), using the read-only
  inventory query from the attendance audit.

---

## 16. Unresolved items

* **Commit inclusion of this document** — whether this plan is committed with the Floating Employees commit or
  separately. The approved manifest (§2) does not include it; §15.1 step 4 excludes it until decided.
* No other approved detail was found to be unrecoverable.
