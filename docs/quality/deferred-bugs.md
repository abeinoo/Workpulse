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
| BUG-005 | Permission payroll effect reads the open period without a lock | Attendance & Payroll | Low | Suspected | Deferred | After Pilot 12 |
| BUG-006 | Device punch reuses a soft-deleted attendance record | Attendance & Payroll | Low | Confirmed (pinned) | Open | Behaviour decision (before API punching) |
| BUG-007 | Advance repayment / deduction arithmetic uses Float | Attendance & Payroll | Low | Confirmed | Deferred | After Modular Monolith |
| BUG-008 | User update keeps new warehouse assignments when the update fails | Organization & Access / Inventory | Low | Confirmed (pinned) | Deferred | After Modular Monolith |
| BUG-009 | Laundry dashboard may pick an inactive laundry branch | Inventory & Purchasing (Laundry) | Low | Confirmed | Deferred | After Pilot 12 |
| BUG-010 | Bulk payment could mark a request paid without an Advance | Workforce | Low (unreachable today) | Suspected (theoretical) | Deferred | After Modular Monolith |
| BUG-011 | `stock_issue_import_spec` intermittent WebDriver failure in CI | Test infrastructure | Low | Confirmed (CI runs), cause unknown | Deferred (test fixes merged in PRs #72 / #73; stability not yet established) | After Pilot 12 |
| BUG-012 | Expenses table scrolls by 2 px at 1440 px with the macOS system font (`expenses_index_responsive_spec.rb` EN @ 1440 px) | Finance & Sales (UI layout) | Low | Confirmed, cause established (2026-10-22): real layout defect under San Francisco; CI fonts fit | **Resolved** (`b6ac0c9`, PR #63) | — |
| BUG-013 | Attendance can be created / edited in a finalized payroll month | Attendance & Payroll | Low | Improvement | Open | Product decision |
| BUG-014 | Laundry consumption report: branch picker and report scope resolve differently | Inventory & Purchasing (Laundry) | Low (usability / filter consistency) | Confirmed (code) | Open | Scope-rule decision |
| BUG-018 | Date-relative specs compute UTC dates; 24 examples fail every day 21:00–24:00 UTC | Test suite (dashboard, payroll, attendance API, custody) | Medium (full-suite gate) | Confirmed (reproduced with a fixed clock) | **Resolved** (`48240b7`, PR #62) | — |
| BUG-019 | English expenses table still overflows at list widths of ~860–900px (viewports ~1324–1364px) | Finance & Sales (UI layout) | Low | Confirmed (measured) | Open | Product / UX decision |
| BUG-015 | Goods receipt void racing approval may overwrite a decided approval status | Inventory & Purchasing | Medium (audit / status integrity; money still balances) | Confirmed (two-connection reproduction, Batch S M1) | **Resolved** (`3f16e92`, PR #60; receipt row lock in `GoodsReceiptVoider#call`) | — |
| BUG-016 | Concurrent voids of a confirmed goods receipt may reverse its stock twice | Inventory & Purchasing | Medium (stock quantity / cost integrity) | Confirmed (two-connection reproduction) | **Resolved** (`3f16e92`, PR #60; same receipt row lock) | — |
| BUG-017 | Concurrent voids of a stock issue, transfer or adjustment duplicate its stock reversal | Inventory & Purchasing | High (stock quantity / cost integrity) | Confirmed (two-connection reproduction) | **Resolved** (`6c2a20e`, PR #61; row lock in `Inventory::DocumentVoider#call`) | — |
| BUG-020 | Admin dashboard shows staff, requests and payroll periods outside the viewer's scope | Reporting (admin dashboard) | **High — critical (unauthorized access, cross-branch)** | Confirmed (request spec on the unchanged code) | **Resolved** (`60d851b`, PR #76; was Escalated) | — |

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

* **Source:** new (noted during the F-A7 approval-race investigation). **Discovered:** 2026-10-21. **Status:** Deferred
  (triaged 2026-10-22, `next-pilot-selection.md` §47: lock the period in the approval transaction).
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

* **Source:** AP-D3 (`next-pilot-selection.md` §10, found in the Pilot 1 M1 characterization, §13); recorded here on
  2026-10-20 as new during the concurrent first-punch investigation. **Discovered:** 2026-10-06 (AP-D3). **Status:**
  Open (triaged 2026-10-22, §47: needs a behaviour decision — restore / refuse / log — before API punching).
* **Domain / files:** Attendance & Payroll — `app/services/attendance/punch_service.rb:93`
  (`AttendanceRecord.find_or_initialize_by(user:, work_date:)`, no `active` scope; no default scope on the model); the
  unique index `index_attendance_records_on_user_id_and_work_date` is not partial.
* **Observed (code):** for a work date whose record was soft-deleted (`deleted_at` set), the lookup finds the deleted
  record and the punch updates it; `deleted_at` stays set.
* **Expected vs actual:** a punch on a day whose record was deleted should create a visible record or be refused
  explicitly; it may update a record that stays deleted (invisible to active scopes).
* **Impact:** a device punch silently disappears from attendance and payroll inputs.
* **Evidence:** Confirmed — pinned as current behaviour (`KNOWN DEFECT AP-D3`) in
  `spec/characterization/attendance_payroll/punch_service_spec.rb:112-124`.
* **Reason for deferral:** found outside the first-punch race scope; behaviour decision needed (restore, refuse, or
  log).
* **Recommended fix:** decide the rule, then apply it in `PunchService` (and check the same lookup in the CSV import).
* **Regression tests:** a punch on a work date with a soft-deleted record — the decided outcome, and its punch log
  (update the pinned AP-D3 example accordingly).
* **Review milestone:** behaviour decision (before API punching).

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
* **Domain / files:** test infrastructure — `spec/system/inventory/stock_issue_import_spec.rb:54`, `:88` and `:118`.
* **Observed:** two CI `system-test` runs on `main` failed with `Selenium::WebDriver::Error::UnknownError` ("Node with
  given id does not belong to the document"); the next run passed.
* **Expected vs actual:** deterministic system tests; intermittent failure, cause unknown.
* **Impact:** unreliable CI signal.
* **Evidence:** Confirmed failures in CI runs 39206655135 and 39365893468; root cause not identified. Not labelled
  flaky.
  * 2026-10-22: the same signature on PR branches that don't touch the import flow. PR #66, run 39765240358
    (attempt 1), failed at `:118` ("Arabic RTL: the upload page and mapping step render right-to-left"). PR #62, run
    39765149279 (attempt 1), failed at `:54`. Each had the same `UnknownError` ("Node with given id does not belong to the
    document"), and `:118` failed through `Capybara::Selenium::Node#visible?` / `ChromeNode#visible?`, like `:88` and
    `:54` in the runs above. Root cause still not identified; status unchanged.
  * 2026-10-22, test-only fixes merged: PR #72 (`a67086e`, merge commit `60c858a`) waits for the mapping step before
    the RTL check; PR #73 (`68c87e1`, merge commit `4c35dfb`) waits for the destination URL after each import submit.
    PR #71 (`f6e9134`) recorded the occurrences above. From #73's merge to 2026-10-25, 34 completed CI `system-test`
    jobs passed (4 cancelled; the one re-run's first attempt passed it too) — too short a record to establish
    stability, so the status stays Deferred.
* **Reason for deferral:** not touched by the migration; needs its own investigation.
* **Recommended fix:** investigate the element lookup / Turbo re-render timing in the import flow.
* **Regression tests:** the spec itself, stable across repeated CI runs.
* **Review milestone:** after Pilot 12.

## BUG-012 — Expenses table scrolls by 2 px at 1440 px with the macOS system font (was: `expenses_index_responsive_spec.rb:121` fails locally by 1 px)

* **Source:** TD-P12-2 (§27.2). **Discovered:** 2026-10-20. **Status:** **Resolved** by `b6ac0c9` (merged into
  `main` in PR #63, merge commit `3a6233e`; narrower widths: BUG-019, open).
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
* **Investigation (2026-10-22) — cause established; not flaky, not a test defect:**
  * *Reproduction:* `expenses_index_responsive_spec.rb[1:5]` ("EN LTR @ 1440px: compact table fits") fails 3 / 3 in
    isolation on a macOS workstation (HeadlessChrome 155, device scale factor 1, viewport 1440 × 1000 by CDP emulation)
    and identically on unchanged `main` `ec8ae59`: `.expense-list__table` `scrollWidth − clientWidth` = 2. Every other
    example of the file (AR @ 1440, all card widths) passes.
  * *Measurement* (scratch CDP diagnostic, same data): the table text renders in **San Francisco** (`.SFNS-Regular` /
    `-Bold`, from `--font: -apple-system, …`). The wrapper is `offsetWidth` 976 / `clientWidth` 974 (1 px border each
    side); the auto-layout table's columns need **975.94 px** (reference 124.56, branch 100, category 100, amount
    145.72, status 164.19, payment 143.47, creator 98.63, actions 99.38 — notes folded at this width), so it overflows by
    ~2 px. With the same page forced to **Arial** (the metrics of Liberation Sans, which CI's `ubuntu-latest` falls back
    to — it has none of `-apple-system`, `BlinkMacSystemFont`, `Segoe UI`, `Roboto`), the table is exactly **974 px**:
    no overflow. CI therefore passes and macOS does not.
  * *Classification:* a **real layout defect** for users whose system font is San Francisco (Chrome / Safari on macOS)
    at a 1440 px viewport in English with this kind of data — a 2 px horizontal scroll inside the table. The assertion
    is correct (it encodes the documented "compact table fits" rule of the stylesheet header). Owner: Finance & Sales UI.
  * *Not fixed* (2026-10-22): every fix changes the table for all users and is a UX choice — e.g. let the status badge
    wrap in table mode (the pattern the payment-source badge already uses), trim the outer cell padding, or fold one
    more column below a wider container breakpoint — and no CI test can prove it (CI cannot render San Francisco).
    Needs a product / UX decision; a font-independent regression check would need a bundled web font or a slack
    margin in the layout.
* **Resolution (2026-10-22, owner decision: let the status badge wrap in table mode):** `.expense-list__status .badge
  { white-space: normal; }` in table mode, `nowrap` in cards — the payment-source badge pattern, without its max-width
  or line-height. With automatic table layout a two-word label ("PENDING APPROVAL" / "بانتظار الاعتماد") usually takes
  two lines; measured, no row grows (rows are already tall from stacked / clamped cells) and the label stays complete
  and unclipped. Overflow at forced list widths, San Francisco / Arial: 976px 2 → 0 / 0 → 0, 940px 38 → 0 / 21 → 0.
  Regression examples in `expenses_index_responsive_spec.rb` (a 940px list fits in EN and AR — this fails before the
  fix with CI-like Arial metrics too, so CI proves it; the wrapped label's readability; cards unchanged). The original
  1440px assertion is unchanged and passes on macOS. Narrower table-mode widths: BUG-019.

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

* **Source:** new (found while fixing BUG-001). **Discovered:** 2026-10-21. **Status:** Open (triaged 2026-10-22,
  `next-pilot-selection.md` §47: needs a scope-rule decision).
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
* **Review milestone:** scope-rule decision.

## BUG-018 — Date-relative specs compute UTC dates; 24 examples fail every day 21:00–24:00 UTC

*(Placed before BUG-015 so this record does not collide with the BUG-017 entry PR #61 appends.)*

* **Source:** new (final migration gate, `next-pilot-selection.md` §48 on the migration stack). **Discovered:**
  2026-10-22. **Status:** **Resolved** by `48240b7` (merged into `main` in PR #62, merge commit `2c27f85`).
* **Domain / files:** test suite — `spec/requests/dashboard_spec.rb`, `spec/services/payroll/auto_generator_spec.rb`,
  `spec/requests/api/v1/attendance_spec.rb`, `spec/system/finance/custody_own_balance_responsive_spec.rb`.
* **Observed:** a full run from 23:40 to 00:04 UTC failed 24 examples (dashboard 4, auto generator 6, attendance API 2,
  own custody ledger 12) that pass at other times.
* **Cause:** the specs computed "today" from the UTC calendar (`Date.current`, the `:for_yesterday` factory trait's
  `Date.yesterday`, `1.day.from_now` / `1.day.ago`, `created_at.to_date` in the test's UTC zone) while the application
  correctly uses the business day (`BusinessDay`, `Payroll::AutoGenerator#today_in_tz`, the request's business
  `Time.zone`). For the factory's Asia/Riyadh (UTC+3) business they disagree every day from 21:00 to 24:00 UTC.
* **Evidence:** reproduced on unchanged `main` with a scratch clock harness (`travel_to` 2026-10-22 22:30 UTC → exactly
  the 24 IDs fail; at 12:00 UTC none of them).
* **Fix:** the four specs compute dates the way the application does (business day / business timezone); no
  expectation weakened, no application change. New `spec/requests/business_day_boundary_spec.rb` (8) pins the
  business-day behaviour of the four paths at fixed instants either side of business midnight (planted UTC-day
  behaviour fails it: 5 and 3 failures).
* **Regression tests:** the four specs pass under the harness at 2026-10-22 20:59:30Z, 21:00:30Z, 22:30Z, 12:00Z and
  2026-10-31 22:30Z (month boundary), and with the real clock; the boundary spec.
* **Review milestone:** — (resolved).

## BUG-019 — English expenses table still overflows at list widths of ~860–900px

*(Placed before BUG-015, like BUG-018, to keep clear of the BUG-017 entry.)*

* **Source:** new (BUG-012 investigation, 2026-10-22). **Status:** Open.
* **Domain / files:** Finance & Sales UI — `app/assets/stylesheets/application.css` (EXPENSES INDEX: table mode from a
  list width of 860px), `app/views/finance/expenses/index.html.erb`.
* **Observed (measured with forced list widths, English; Arabic never overflows):** before the BUG-012 fix, San
  Francisco / Arial: 940px 38 / 21px, 900px 78 / 61px, 880px 98 / 81px, 860px 118 / 101px. After it: 940px 0 / 0,
  900px 18 / 2px, 880px 38 / 22px, 860px 58 / 42px. The list is ~976px at a 1440px viewport, so ~860–900px corresponds
  to viewports of roughly 1324–1364px.
* **Expected vs actual:** the stylesheet's rule is that table mode fits without horizontal scrolling from 860px of list
  width; English needs more there.
* **Impact:** a horizontally scrolling table on mid-size desktop screens in English. No data or behaviour impact.
* **Evidence:** Confirmed (measured); the existing spec checks table mode only at 1440px.
* **Recommended fix (needs a UX decision):** raise the English card / table threshold, fold one more column into a
  stacked cell between 860 and ~940px (as the notes column already folds), or let another long label wrap; add a table
  example at a list width just above 860px.
* **Review milestone:** product / UX decision.

## BUG-015 — Goods receipt void racing approval may overwrite a decided approval status

* **Source:** new (Batch S M0 inventory, `docs/architecture/inventory-finance-goods-receipt-payments-baseline-failures.txt`). **Discovered:** 2026-10-21. **Status:** **Resolved**
  (2026-10-21) by the separately approved fix `3f16e92` (merged into `main` with Batch S in PR #60, merge commit
  `ec8ae59`): `GoodsReceiptVoider#call` locks and reloads the receipt (`@receipt.lock!`) first inside its transaction.
  Was: recorded as suspected at Batch S M0, then reproduced at M1.
* **Domain / files:** Inventory & Purchasing — `app/services/inventory/goods_receipt_voider.rb` (`#call`,
  `#void_unconfirmed!`, `#cancel_undecided_approval!`), against `app/services/inventory/goods_receipt_approval.rb`
  (`#approve!`, `receipt.with_lock`).
* **Observed (code):** the voider takes no explicit lock on the receipt; it checks `voided?` and reads
  `approval_status` from an unlocked load. Its first `update!` waits on the approval's row lock, then
  `cancel_undecided_approval!` uses the stale in-memory `pending_approval` and writes `approval_status: "cancelled"`.
* **Expected vs actual (suspected):** a decided approval is kept as history (the voider's own comment); if the void
  commits after a concurrent approval, the receipt could read voided + cancelled although it was approved. Its
  `reverse_all` runs after the approval committed and reverses the new payment, so the money balances.
* **Impact:** approval history / status integrity; the void audit records a false `pending_approval → cancelled`
  transition for an approved receipt.
* **Evidence:** reproduced deterministically by
  `spec/characterization/inventory_purchasing/goods_receipt_payments_concurrency_spec.rb` ("approval first, void
  second"; two connections, queue handshake, no sleeps) under seeds 20261006, 12345, 98765 and CI=1: the approval
  commits (`approve` audit `pending_approval → approved`, one 250.00 custody settlement); the void, which waited on the
  receipt row, then writes `approval_status: "cancelled"` and audits `void` with `approval_status
  ["pending_approval", "cancelled"]` — a transition that never happened. Money balances: the payment is reversed with a
  custody credit and the cached balance equals the ledger (1,000.00). The example asserts the safe invariant (status
  kept as `approved`) and therefore failed until fixed.
* **Resolution evidence:** with the lock the void waits on the receipt row `FOR UPDATE`, reloads it after the approval
  commits and keeps `approved` (it voids the receipt and reverses the payment, audit `void` without an approval
  change); the same example passes unchanged under seeds 20261006, 12345, 98765 and CI=1. Lock order for every
  goods-receipt path is now receipt first (approval, confirmation, later settlement, single reversal, void).
* **Reason for deferral / prioritization (at M0):** not shown to occur; Batch S is a behaviour-preserving refactor (a
  lock is a behaviour change needing its own approval). Superseded by the reproduction and the approved fix.
* **Recommended fix:** lock the receipt (`@receipt.lock!`, reloading it) at the start of the void transaction and
  re-check `voided?` / `approval_status` under the lock — the order the other goods-receipt paths use.
* **Regression tests:** two-connection approve vs void in both orders: the receipt ends either approved-then-voided with
  its approval status kept, or voided with the approval refused.
* **Review milestone (at M0):** after Batch S — closed by the fix.

## BUG-016 — Concurrent voids of a confirmed goods receipt may reverse its stock twice

* **Source:** new (Batch S M0). **Discovered:** 2026-10-21. **Status:** **Resolved** (2026-10-21) by the
  BUG-015 fix `3f16e92` (same receipt row lock; PR #60). Was: suspected at Batch S M0, then reproduced.
* **Domain / files:** Inventory & Purchasing — `app/services/inventory/goods_receipt_voider.rb`,
  `app/services/inventory/document_voider.rb` (`#call`).
* **Observed (code):** `DocumentVoider` checks `voided?` on an unlocked load and inserts the reversal
  `inventory_movements` before its `update!`; nothing locks the receipt first. Two concurrent voids could both pass the
  guard and both commit their reversal movements (the second `update!` waits, then succeeds).
* **Expected vs actual (suspected):** one stock reversal per receipt; possibly two, with a second `void` audit and an
  overwritten `voided_at`. Settlements are not affected: `reverse_all` reads only unreversed originals and the unique
  index on `reverses_settlement_id` blocks a second reversal.
* **Impact:** stock quantities and moving-average cost of the receipt's products.
* **Evidence:** reproduced on the unchanged code by `spec/services/inventory/goods_receipt_void_concurrency_spec.rb`
  (two connections, queue handshake, no sleeps): both voids succeeded — a confirmed 10-unit receipt got two stock
  reversals (on-hand 0 → **−10**), two `void` audits and an overwritten `voided_by`; settlements and custody were
  already single (500 / −500, balance 1,000). With the receipt row lock the second void waits, reloads the receipt and
  is refused (`has already been voided`): one reversal, on-hand 0, average cost 0, one audit — both examples
  (confirmed and approved-unconfirmed) pass under seeds 20261006, 12345, 98765 and CI=1. `DocumentVoider` itself is
  unchanged; the receipt is locked by its caller, `GoodsReceiptVoider` (stock issues, stock transfers and stock adjustments,
  which call `DocumentVoider` directly from their controllers, were not examined — follow-up work).
* **Reason for deferral / prioritization (at M0):** not shown to occur; outside the payment boundary of Batch S.
  Superseded by the reproduction and the BUG-015 fix.
* **Recommended fix:** lock the document row before the `voided?` guard in `DocumentVoider` (and in the goods-receipt
  voider), so the second void sees it voided and is refused.
* **Regression tests:** two-connection double void of a confirmed receipt → one set of reversal movements, the second
  void refused with `already_voided`.
* **Review milestone (at M0):** after Batch S — closed by the fix.

## BUG-017 — Concurrent voids of a stock issue, transfer or adjustment duplicate its stock reversal

* **Source:** new (follow-up of BUG-016, read-only investigation 2026-10-21). **Discovered:** 2026-10-21. **Status:**
  **Resolved** (2026-10-22) by `6c2a20e` (PR #61, merge commit `ca4b43d`): `Inventory::DocumentVoider#call` opens its
  transaction first and locks and reloads the document (`@document.lock!`) before its guards.
* **Domain / files:** Inventory & Purchasing — `app/services/inventory/document_voider.rb` (`#call`), called by
  `Inventory::StockIssuesController#void`, `Inventory::StockTransfersController#void`,
  `Inventory::StockAdjustmentsController#void` (each on a `policy_scope(...).find` copy) and `GoodsReceiptVoider`.
* **Observed (code, before the fix):** the `voided?`, reason and stock-availability guards ran on an unlocked copy
  before the transaction; the reversal `inventory_movements` were inserted before the void `update!`, which was the
  only statement that waited on the row; `inventory_movements` has no per-document uniqueness to stop a second set.
* **Expected vs actual:** one reversal per document, the second void refused as already voided. Reproduced on the
  unchanged code (two connections, the first void paused inside its transaction): both voids succeeded — a stock issue
  of 4 returned 8 (stock 14 instead of 10), a transfer of 6 was reversed twice (Main 16 / Branch **−6**, past the
  availability guard), an adjustment of −3 returned 6 (13 instead of 10); every time two reversal sets and
  `voided_by` / `void_reason` overwritten by the second void.
* **Impact:** stock quantities (including negative stock) and, through `ProductCostRecalculator`, moving-average cost.
* **Evidence:** `spec/services/inventory/document_voider_concurrency_spec.rb` (3 examples: stock issue, transfer,
  adjustment) — fails on the unchanged code (the lock neutralized in memory: the same duplicates and −6) and passes
  with the fix under seeds 20261006, 12345, 98765 and CI=1: the second void waits on the document row, then is refused
  (`already_voided`), one reversal set, stock restored once, the first voider kept.
* **Fix:** the transaction opens first; `@document.lock!` reloads the row under the lock; the existing guards (same
  order, same messages) run on it and a refusal leaves the block writing nothing; then the reversal movements, the void
  metadata and the cost recompute, as before. `GoodsReceiptVoider` (which locks the receipt first, BUG-015) re-locks
  the same row harmlessly.
* **Not in scope:** stock-document voids still write no audit row (a separate product decision); a void racing a
  confirmation or edit of the same document was not investigated.
* **Regression tests:** the concurrency spec above; `document_voider_spec.rb` (sequential guards) unchanged and passing.
* **Review milestone:** — (resolved).

## BUG-020 — Admin dashboard shows staff, requests and payroll periods outside the viewer's scope

* **Source:** A1 (architecture / API-readiness audit, 2026-10-25). **Discovered:** 2026-10-25. **Status:** **Resolved**
  by `60d851b` "fix: scope admin dashboard data to the viewer's policy scopes (BUG-020)" (2026-10-25; merged into
  `main` in PR #76, merge commit `9be4145`): the dashboard reads through the existing policy scopes. Was
  **Escalated** — critical under the policy (cross-branch exposure).
* **Domain / files:** Reporting — `app/controllers/admin/dashboard_controller.rb` (`#index`),
  `app/views/admin/dashboard/index.html.erb`; gate `Admin::BaseController#require_admin_access!`.
* **Observed (code, before the fix):** the gate admits any one of 13 permissions, six of them scopable
  (`view_employees`, `manage_employees`, `view_attendance`, `manage_attendance`, `view_payroll`,
  `manage_salary_profiles`; the branch-manager role holds three). `#index` then read `business.users`,
  `EmployeeRequest.for_business(...)` and `PayrollPeriod.where(branch: business.branches)` with no policy scope.
* **Expected vs actual:** a viewer sees what `admin/users#index` (`UserPolicy::Scope`), the requests list
  (`EmployeeRequestPolicy::Scope`) and `payroll_periods#index` (`PayrollPeriodPolicy::Scope`) show them; instead a
  branch manager saw every employee's name, role and status, the business-wide headcount and pending-request count,
  and branch-tagged payroll periods of other branches — drafts included, also for viewers without
  `view_draft_payroll`. Same business only; no money figures; period links led to scoped pages (404).
* **Impact:** cross-branch disclosure of staff identity / role / status and payroll-period existence and status. The
  payroll part is limited to legacy branch-tagged periods (new periods carry no branch); production data not checked.
* **Evidence:** `spec/requests/admin/dashboard_spec.rb` — on the unchanged code 10 of 12 examples fail (another
  branch's employee and finalized period shown, counts 3 instead of 2, draft shown without draft access); with the fix
  12 / 0.
* **Fix:** `#index` uses `policy_scope(User)` for the list and headcount (owner still excluded from the count),
  `policy_scope(EmployeeRequest)` for the pending count, and `policy_scope(PayrollPeriod)` intersected with the
  existing branch-tagged selection. Owner and business-scoped viewers unchanged; the branch and active-shift counts
  (business configuration) unchanged; no route, view, policy or gate change.
* **Not in scope:** the gate still admits non-scopable admin permissions (they now see only their own data);
  controller-wide Pundit enforcement (audit S5); the payroll section not listing current (branch-less) periods (a
  feature decision).
* **Regression tests:** `spec/requests/admin/dashboard_spec.rb` (12: branch manager with the hierarchy default and with
  an explicit branch scope, business-scoped viewer without draft access, owner, `manage_devices`-only viewer, other
  business, non-admin redirect, parity with the employee list).
* **Review milestone:** — (resolved).
