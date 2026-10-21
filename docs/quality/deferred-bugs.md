# Deferred bugs and technical issues

Backlog of bugs and technical issues found during the Modular Monolith migration that were **not** fixed in the task
that found them. Policy: critical issues (security, unauthorized access, financial / payroll corruption, irreversible
data loss, integrity failures affecting the current task) are fixed immediately; migration-blocking issues are fixed in
the pilot; everything else is recorded here and the pilot continues. Review this backlog at the end of every pilot and
before declaring the migration ready for API implementation.

**IDs are stable** (`BUG-NNN`, never reused or renumbered). Where an issue was first recorded in
`docs/architecture/next-pilot-selection.md`, its original ID is kept as **Source** so the two never diverge; the
architecture document stays the record of how it was found.

**Evidence levels:** *Confirmed* — shown by a test, a reproduction or unambiguous code; *Suspected* — code-evident but
not reproduced; *Improvement* — not a defect, a behaviour change needing a product decision.

**Statuses:** Open (not yet triaged for a slot) · Deferred (triaged, waiting for its milestone) · In Progress ·
Resolved (only after the fix and its focused verification completed). **Escalated** marks an issue that is critical
under the policy (or blocks the current pilot): it requires immediate remediation, is **not** deferred, and is listed
here only so its stable ID and history are kept.

## Summary

| ID | Title | Domain | Priority | Evidence | Status | Review milestone |
|---|---|---|---|---|---|---|
| BUG-001 | Laundry branch consumption report shows every branch when no branch is chosen | Inventory & Purchasing (Laundry) | **High — critical (unauthorized access)** | Confirmed | **Resolved** (`3139cf4`, was Escalated) | — |
| BUG-002 | Concurrent check-outs on one attendance record: last commit wins | Attendance & Payroll | Medium | Confirmed (reasoning) | Deferred | After Pilot 12 |
| BUG-003 | Audit failures inside a transaction are swallowed | Shared (`AuditLoggable`) | Medium (low likelihood) | Suspected | Deferred | After Pilot 12 |
| BUG-004 | Manual-entry / CSV attendance check the payroll lock without a row lock | Attendance & Payroll | Low | Suspected | Deferred | After Pilot 12 |
| BUG-005 | Permission payroll effect reads the open period without a lock | Attendance & Payroll | Low | Suspected | Open | After Pilot 12 |
| BUG-006 | Device punch reuses a soft-deleted attendance record | Attendance & Payroll | Low | Suspected | Open | After Pilot 12 |
| BUG-007 | Advance repayment / deduction arithmetic uses Float | Attendance & Payroll | Low | Confirmed | Deferred | After Modular Monolith |
| BUG-008 | User update keeps new warehouse assignments when the update fails | Organization & Access / Inventory | Low | Confirmed (pinned) | Deferred | After Modular Monolith |
| BUG-009 | Laundry dashboard may pick an inactive laundry branch | Inventory & Purchasing (Laundry) | Low | Confirmed | Deferred | After Pilot 12 |
| BUG-010 | Bulk payment could mark a request paid without an Advance | Workforce | Low (unreachable today) | Suspected (theoretical) | Deferred | After Modular Monolith |
| BUG-011 | `stock_issue_import_spec` intermittent WebDriver failure in CI | Test infrastructure | Low | Confirmed (CI runs), cause unknown | Deferred | After Pilot 12 |
| BUG-012 | `expenses_index_responsive_spec.rb:121` fails locally by 1 px | Test infrastructure | Low | Confirmed (one local run), cause unknown | Deferred | After Pilot 12 |
| BUG-013 | Attendance can be created / edited in a finalized payroll month | Attendance & Payroll | Low | Improvement | Open | Product decision |
| BUG-014 | Laundry consumption report: branch picker and report scope resolve differently | Inventory & Purchasing (Laundry) | Low (usability / filter consistency) | Confirmed (code) | Open | After Pilot 12 |

---

## BUG-001 — Laundry branch consumption report shows every branch when no branch is chosen

* **Source:** TD-P11-1 (`next-pilot-selection.md` §26.4). **Discovered:** 2026-10-19. **Status:** **Resolved** by `3139cf4`
  "fix: enforce branch scope in laundry consumption reports" (2026-10-21; was Escalated — immediate remediation).
* **Domain / files:** Inventory & Purchasing (Laundry) — `app/controllers/laundry/reports/branch_consumption_controller.rb:33-42`
  (`#scoped_branch_id`, line 34), `app/services/laundry/branch_towel_consumption_report.rb:78`.
* **Observed:** `#scoped_branch_id` returns `nil` when `branch_id` is blank, before the scope check; the report filters
  by branch only when one is given. `view_laundry_consumption_reports` is in `BRANCH_SCOPABLE_PERMISSIONS`.
* **Expected vs actual:** a branch-scoped viewer should see only their branches; opening the report with no filter (the
  default page) shows every sales branch's towel counts and laundry cost totals, in HTML and CSV (same business).
* **Impact:** cross-branch data exposure (operational / cost data) — **unauthorized access, so critical under the
  policy: escalated, not deferred.**
* **Evidence:** Confirmed by code. `spec/requests/laundry/cost_reports_authorization_spec.rb:58-67` cannot catch it (the
  other branch has no transfers, so it could never appear).
* **Reason not fixed yet:** found during a read-only risk review (2026-10-21); F-A5 was prioritised first.
* **Recommended fix:** when no branch is given and the viewer is not business-scoped, restrict the report to the
  viewer's allowed branch ids (`BranchScope#for_scope`); keep the explicit-`branch_id` clamp.
* **Regression tests:** another branch's real transfers hidden for a branch-scoped viewer (HTML and CSV); owner and
  business-scoped viewer still see all; an explicit out-of-scope `branch_id` still clamped.
* **Review milestone:** immediate — the next task, before further laundry / reporting work.
* **Resolution:** the report takes the viewer's branch scope (`branch_ids:`; nil for owner / business scope, `[]` for
  none) and applies it in the query; the controller resolves it once, so the page, totals and CSV share one scoped
  result; an out-of-scope `branch_id` is still clamped to the first allowed branch. Also fixed: a viewer with no allowed
  branch got every branch for an explicit `branch_id`. Verified by
  `spec/requests/laundry/branch_consumption_scope_spec.rb` (10, real transfers from two branches; the original
  controller fails 5) and the focused laundry set (181 examples, 0 failures, normal and `CI=1`, seeds 20261021 and 7).

## BUG-002 — Concurrent check-outs on one attendance record: last commit wins

* **Source:** §35 residual risk. **Discovered:** 2026-10-20. **Status:** Deferred.
* **Domain / files:** Attendance & Payroll — `app/services/attendance/punch_service.rb` (`#process`,
  `#perform_check_out`).
* **Observed:** two device punches for an *existing* record both read the old state and both update it; there is no
  row lock on the attendance record (only the shared `FOR SHARE` payroll-period lock).
* **Expected vs actual:** the latest punch should be the check-out and the second a `rejected_spam` / no-op; the last
  commit wins instead, which can keep the earlier check-out, and two `check_out` logs are written.
* **Impact:** wrong worked / early-leave minutes, which feed payroll; no HTTP error.
* **Evidence:** Confirmed by code and PostgreSQL READ COMMITTED reasoning; not reproduced by a test.
* **Reason for deferral:** narrow window (simultaneous punches of one employee); the first-punch insert race was the
  urgent part (fixed, `b14744a`); the lock design was explicitly deferred.
* **Recommended fix:** a per-employee transaction-level advisory lock (or `FOR UPDATE` on the record) before the lookup;
  lock order period `FOR SHARE` → employee lock → record → log.
* **Regression tests:** two-connection example in `spec/services/attendance/punch_period_lock_spec.rb` — two check-outs
  of one record, the later time wins, one `check_out` log.
* **Review milestone:** after Pilot 12.

## BUG-003 — Audit failures inside a transaction are swallowed

* **Source:** F-A4 (§29). **Discovered:** 2026-10-20. **Status:** Deferred.
* **Domain / files:** shared — `app/models/concerns/audit_loggable.rb:12-24` (`log_audit` rescues every error); callers
  that audit inside a transaction (e.g. `Requests::Approver#pay`, `#approve_standard`, `#reject`, `Requests::Canceller`).
* **Observed:** `log_audit` rescues and logs any exception. A database-level `AuditLog` insert failure inside a
  PostgreSQL transaction aborts it, but the rescue hides that; the commit then rolls back silently while the service
  returns success.
* **Expected vs actual:** a failed audit should either roll back visibly or not affect the main operation; today the
  main operation may be lost while reported as successful.
* **Impact:** a payment / approval reported as done but not persisted (if an audit insert ever fails at the database).
* **Evidence:** Suspected — code pattern only; no database-level audit failure is known to occur.
* **Reason for deferral:** cross-cutting (every audited service), low likelihood; `OrganizationAccess::DeleteUser`
  already uses `AuditLog.create!` for this reason.
* **Recommended fix:** write the audit in a savepoint (`requires_new`) or let audit errors propagate inside
  transactions — one shared change, decided once.
* **Regression tests:** a service example forcing a database-level audit failure inside the transaction: the result
  reports failure, or the main change persists, consistently.
* **Review milestone:** after Pilot 12.

## BUG-004 — Manual-entry / CSV attendance check the payroll lock without a row lock

* **Source:** §33 residual risk (decision D-L2). **Discovered:** 2026-10-20. **Status:** Deferred.
* **Domain / files:** Attendance & Payroll — `app/services/attendance/bulk_manual_entry_service.rb:116-120`
  (`#period_locked?`, plain `find_by`); the manual-records CSV import path.
* **Observed:** the locked-period check reads the payroll period without a lock, the same race class TD-T-1 fixed for
  device punches (`5925411`).
* **Expected vs actual:** an entry should never land in a month finalized concurrently; a finalization committing
  between the check and the write is not seen.
* **Impact:** attendance written into a just-finalized month (entries computed without it).
* **Evidence:** Suspected — code-evident, window is one request; not reproduced.
* **Reason for deferral:** explicitly kept out of TD-T-1's scope (D-L2).
* **Recommended fix:** the TD-T-1 pattern — `PayrollPeriod.lock("FOR SHARE")` inside a transaction around the write.
* **Regression tests:** two-connection example modelled on `spec/services/attendance/punch_period_lock_spec.rb`.
* **Review milestone:** after Pilot 12.

## BUG-005 — Permission payroll effect reads the open period without a lock

* **Source:** new (noted during the F-A7 approval-race investigation). **Discovered:** 2026-10-21. **Status:** Open.
* **Domain / files:** Attendance & Payroll — `app/services/payroll/permission_applier.rb` (`#open_period_covering`,
  plain `where.not(status: %w[finalized paid]).first`).
* **Observed:** approving a late-permission / early-leave request rewrites a payroll line item of the open period; the
  period is read without a lock, so a concurrent finalization is not serialized with it.
* **Expected vs actual:** a permission effect should not change an entry of a period being finalized; it may.
* **Impact:** a line item changed in a just-finalized period.
* **Evidence:** Suspected — code-evident, not reproduced; same race class as BUG-004.
* **Reason for deferral:** found outside the F-A7 scope; low likelihood.
* **Recommended fix:** read the period `FOR SHARE` (or `FOR UPDATE`) inside the approval transaction (approval is one
  transaction since `0c0b57b`; lock order request → period → entry).
* **Regression tests:** two-connection example — a permission approval paused after its period read vs
  `Payroll::Approver.advance`.
* **Review milestone:** after Pilot 12.

## BUG-006 — Device punch reuses a soft-deleted attendance record

* **Source:** new (noted during the concurrent first-punch investigation). **Discovered:** 2026-10-20. **Status:** Open.
* **Domain / files:** Attendance & Payroll — `app/services/attendance/punch_service.rb:93`
  (`AttendanceRecord.find_or_initialize_by(user:, work_date:)`, no `active` scope; no default scope on the model); the
  unique index `index_attendance_records_on_user_id_and_work_date` is not partial.
* **Observed (code):** for a work date whose record was soft-deleted (`deleted_at` set), the lookup finds the deleted
  record and the punch updates it; `deleted_at` stays set.
* **Expected vs actual:** a punch on a day whose record was deleted should create a visible record or be refused
  explicitly; it may update a record that stays deleted (invisible to active scopes).
* **Impact:** a device punch silently disappears from attendance and payroll inputs.
* **Evidence:** Suspected — code-evident; not reproduced.
* **Reason for deferral:** found outside the first-punch race scope; behaviour decision needed (restore, refuse, or
  log).
* **Recommended fix:** decide the rule, then apply it in `PunchService` (and check the same lookup in the CSV import).
* **Regression tests:** a punch on a work date with a soft-deleted record — the decided outcome, and its punch log.
* **Review milestone:** after Pilot 12.

## BUG-007 — Advance repayment / deduction arithmetic uses Float

* **Source:** F-A6 (§29). **Discovered:** 2026-10-20. **Status:** Deferred.
* **Domain / files:** Attendance & Payroll — `app/services/payroll/advance_deductor.rb:31` (`remaining_amount.to_f`),
  `app/models/advance.rb:16` (`amount.to_f`).
* **Observed:** money converted to Float before arithmetic, rounded to 2 decimals afterwards.
* **Expected vs actual:** money in `BigDecimal` throughout (CLAUDE.md money rules); Float can drift at the cent level.
* **Impact:** possible one-cent differences in deductions or remaining balances.
* **Evidence:** Confirmed by code; no observed wrong amount.
* **Reason for deferral:** low impact; touches payroll calculation, best done with payroll characterization.
* **Recommended fix:** `to_d` instead of `to_f` in both places.
* **Regression tests:** amounts that drift in Float (e.g. repeated 0.1 / 0.7 deductions) keep exact `BigDecimal`
  results.
* **Review milestone:** after Modular Monolith completion.

## BUG-008 — User update keeps new warehouse assignments when the update fails

* **Source:** TD-W-1 (§28.3). **Discovered:** 2026-10-20. **Status:** Deferred.
* **Domain / files:** Organization & Access / Inventory & Purchasing — `app/models/user.rb:39`
  (`has_many :assigned_warehouses, through: :warehouse_assignments`), `Admin::UsersController#update`.
* **Observed:** the `has_many :through` ids writer saves join rows immediately during `assign_attributes`.
* **Expected vs actual:** a failed update (422) or a refused role change should change nothing; the new warehouse
  assignments are kept.
* **Impact:** form not atomic; no authority gained (the actor was already authorized).
* **Evidence:** Confirmed — pinned as current behaviour in the Batch W specs.
* **Reason for deferral:** user decision 2026-10-20 — keep the timing in the migration; all-or-nothing save is a
  separate approved change.
* **Recommended fix:** assign warehouse ids only after the user saves, in one transaction.
* **Regression tests:** the two pinned cases (validation failure, refused role change) then expect no new
  assignments.
* **Review milestone:** after Modular Monolith completion.

## BUG-009 — Laundry dashboard may pick an inactive laundry branch

* **Source:** TD-P11-2 (§26.4). **Discovered:** 2026-10-19. **Status:** Deferred.
* **Domain / files:** Inventory & Purchasing (Laundry) — `app/controllers/laundry/dashboard_controller.rb:13`
  (`branch_type_laundry.first`).
* **Observed:** no `active` filter and no order on the laundry-branch lookup.
* **Expected vs actual:** the dashboard should use the active laundry branch the reports use; it may pick an inactive
  one, so the dashboard can disagree with the report.
* **Impact:** confusing balances on the dashboard only.
* **Evidence:** Confirmed by code.
* **Reason for deferral:** low impact, unrelated to the current pilot.
* **Recommended fix:** the same active, deterministic lookup as the reports.
* **Regression tests:** an inactive laundry branch created first is not the one shown.
* **Review milestone:** after Pilot 12.

## BUG-010 — Bulk payment could mark a request paid without an Advance

* **Source:** §36 limits. **Discovered:** 2026-10-20. **Status:** Deferred.
* **Domain / files:** Workforce — `app/services/requests/bulk_payment_service.rb` (one outer transaction),
  `app/services/requests/approver.rb` (`#pay` rescues `RecordInvalid` inside the joined transaction).
* **Observed (code):** if `Advance.create!` raised `RecordInvalid` after the request's `update!` to paid, `#pay` would
  rescue it inside the batch transaction, which then commits the request as paid with no Advance (reported skipped).
* **Expected vs actual:** a payment is atomic; this path would break it.
* **Impact:** a paid request with no payroll deduction.
* **Evidence:** Suspected, theoretical — unreachable today (a valid salary advance always yields a valid Advance).
* **Reason for deferral:** unreachable; becomes relevant only if Advance gains validations.
* **Recommended fix:** a savepoint per bulk item (`requires_new` in `#pay`'s transaction).
* **Regression tests:** an Advance validation failure in a batch leaves that request approved.
* **Review milestone:** after Modular Monolith completion.

## BUG-011 — `stock_issue_import_spec` intermittent WebDriver failure in CI

* **Source:** TD-P12-1 (§27.2). **Discovered:** 2026-10-20. **Status:** Deferred.
* **Domain / files:** test infrastructure — `spec/system/inventory/stock_issue_import_spec.rb:54` and `:88`.
* **Observed:** two CI `system-test` runs on `main` failed with `Selenium::WebDriver::Error::UnknownError` ("Node with
  given id does not belong to the document"); the next run passed.
* **Expected vs actual:** deterministic system tests; intermittent failure, cause unknown.
* **Impact:** unreliable CI signal.
* **Evidence:** Confirmed failures in CI runs 39206655135 and 39365893468; root cause not identified. Not labelled
  flaky.
* **Reason for deferral:** not touched by the migration; needs its own investigation.
* **Recommended fix:** investigate the element lookup / Turbo re-render timing in the import flow.
* **Regression tests:** the spec itself, stable across repeated CI runs.
* **Review milestone:** after Pilot 12.

## BUG-012 — `expenses_index_responsive_spec.rb:121` fails locally by 1 px

* **Source:** TD-P12-2 (§27.2). **Discovered:** 2026-10-20. **Status:** Deferred.
* **Domain / files:** test infrastructure — `spec/system/finance/expenses_index_responsive_spec.rb:121` (assertion at
  line 128).
* **Observed:** `.expense-list__table` `scrollWidth - clientWidth` was 2 (expected ≤ 1) in one local full-suite run; CI
  passed on the same commit.
* **Expected vs actual:** the compact table fits at 1440 px; locally it overflowed by 1 px once.
* **Impact:** local test noise only.
* **Evidence:** Confirmed once locally; a browser / font difference is a hypothesis, not verified. Not labelled flaky.
* **Reason for deferral:** not touched by the migration.
* **Recommended fix:** reproduce locally and compare fonts / browser version with CI.
* **Regression tests:** the spec itself, passing locally and in CI.
* **Review milestone:** after Pilot 12.

## BUG-013 — Attendance can be created / edited in a finalized payroll month

* **Source:** new (observed during the 2026-10-21 risk review). **Discovered:** 2026-10-21. **Status:** Open.
* **Domain / files:** Attendance & Payroll — `app/services/attendance/manual_entry_service.rb`,
  `app/services/attendance/adjustment_service.rb` (no locked-period refusal; payroll recalculation skipped when the
  period is not editable).
* **Observed:** single manual entry and attendance edit succeed in a finalized / paid month, while deletion
  (`RecordDeleter`), device punches and punch corrections are refused there.
* **Expected vs actual:** a consistent rule for locked months; today attendance and the finalized payroll can diverge.
* **Impact:** attendance no longer matches finalized payroll; no payroll change.
* **Evidence:** Improvement — pinned as intended in `spec/services/attendance/adjustment_service_spec.rb:299-311`
  ("attendance edit is independent of payroll lock"); not a defect until a product decision says otherwise.
* **Reason for deferral:** product decision required.
* **Recommended fix:** decide whether locked months refuse manual create / edit (like delete) or keep allowing them.
* **Regression tests:** depend on the decision (update the pinned adjustment examples accordingly).
* **Review milestone:** product decision.

## BUG-014 — Laundry consumption report: branch picker and report scope resolve differently

* **Source:** new (found while fixing BUG-001). **Discovered:** 2026-10-21. **Status:** Open.
* **Domain / files:** Inventory & Purchasing (Laundry) — `app/controllers/laundry/reports/branch_consumption_controller.rb`
  (`@branches = assignable_branches`, the filter picker) vs `#allowed_branch_ids` (the report data);
  `app/controllers/laundry/base_controller.rb` (`#assignable_branches`).
* **Observed (code):** the picker resolves branches from the `view_towel_balances` scope (default) with
  `include_shift_assignments: true`; the report data uses the `view_laundry_consumption_reports` scope without shift
  assignments (the resolution it already used for explicit filters before BUG-001).
* **Expected vs actual:** the picker should offer exactly the branches the report can show; it can list a branch whose
  results are then clamped away (the report shows the viewer's first allowed branch instead), or omit a branch the
  report would show. Open scope question, not a defect claim: a shift-assigned (non-manager) viewer with a `branch`
  scope gets an empty report, while the laundry policies count shift assignments.
* **Classification:** usability / filter-consistency issue — **not a data leak**: the report data itself is scoped
  (BUG-001); the picker only lists branch names.
* **Impact:** confusing or misleading filter choices for scoped viewers.
* **Evidence:** Confirmed by code; not reported by users.
* **Reason for deferral / prioritization:** Low — no access-control or financial impact, so not critical under the
  policy; fixing it needs a scope-rule decision (should the report scope count shift assignments, like the laundry
  policies?) and was outside BUG-001.
* **Recommended fix:** decide the rule, then derive both the picker and the report from the same resolution.
* **Regression tests:** a viewer whose two permissions resolve differently sees the same branches in the picker and the
  report; the decided shift-assignment case.
* **Review milestone:** after Pilot 12.
