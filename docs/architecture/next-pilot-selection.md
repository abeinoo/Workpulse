# Next Migration Pilot — Candidate Analysis

**Status:** ANALYSIS ONLY. **No pilot has been selected.** The final choice is a separate human decision.
**Baseline:** `feature/api-foundation` @ `c1aac8b`.
**Method:** `docs/architecture/migration-pattern.md` §12 (weighted 1–3 scores, disqualifiers, dependency-order
tie-break), within the six domains of `docs/architecture/module-boundaries.md`.
**Evidence:**

* Read-only commands against the repository: reference scans of `app/` and `lib/` (code lines, comments ignored),
  spec dry-runs, `db/schema.rb`, `db/migrate/*`, and `docs/architecture/permission-role-baseline-failures.txt`.
* Read-only queries on the development database (stored type names).

---

## 1. Executive summary

* **Candidates analysed:** 7.
  * **NOT ELIGIBLE (2):** `Branch` (too coupled; an unresolved Organization & Access → Workforce inversion; 8 data
    migrations) and the `ShiftTemplate` group (its core operation is broken in the baseline: 10 failing
    `TemplateApplier` examples plus 1 request example).
  * **ELIGIBLE (5).**
* **RECOMMENDED FOR REVIEW (3):**

  | Candidate | Domain | Weighted score |
  |---|---|---|
  | `UserAuditLog` | Organization & Access | 31 |
  | Department + JobTitle catalogs | Workforce | 39 |
  | BiometricDevice group | Attendance & Payroll | 41 |

* **ELIGIBLE but not shortlisted:** EmployeeDataRequest group (43) and the Performance evaluation group (45).
* **Lowest score is not automatically the choice.** `UserAuditLog` scores lowest but exercises only a small part of
  the pattern (§8). The trade-off between "lowest risk" and "most learning / dependency order" is left to the
  reviewer (§10).

---

## 2. Six-domain inventory (repository evidence)

230 model files; service and controller namespaces as found under `app/`. The domain assignment follows
`module-boundaries.md` §4–§10.

| Domain | Major components (models / services / controllers) |
|---|---|
| **1. Organization & Access** | `Business`, `Branch`, `User` (account), `PermissionRole` (pilot complete), `UserAuditLog`, `AuditLog`. **Services:** `organization_access/` (9), `employee_scope`, `branch_scope`, `branch_membership` (contract), `users/`. **Controllers:** `admin/` (users, branches, permission roles, settings), `users/`, API sessions |
| **2. Workforce** | `Department`, `JobTitle`, `Shift`, `ShiftAssignment`, `ShiftTemplate(+Entry)`, `ShiftRuleProfile`, `EmployeeRequest`, `EmployeeDataRequest(+Event, +Revision)`, `EmployeeInsuranceProfile`, `PerformanceReview(+Score)`, `PerformanceObservation`, `EvaluationTemplate`, `EvaluationCriterion`. **Services:** `shifts/` 3, `scheduling/` 3, `requests/` 5, `employee_data_requests/` 6, `performance/` 6, `employee/` 2. **Controllers:** `performance/` 5, shift assignments, admin shift templates/departments/job titles |
| **3. Attendance & Payroll** | `AttendanceRecord`, `AttendanceAdjustment`, `AttendanceImportLog`, `BiometricDevice`, `BiometricPunchLog`, `PayrollPeriod`, `PayrollEntry`, `PayrollLineItem`, `PayrollAdjustment(+Edit)`, `PayrollAuditLog`, `PayrollSnapshot`, `PayrollPeriodBranchReview`, `SalaryProfile`, `Advance`, `BalanceRequest`, `EmployeeObligation`, `ObligationDeduction` / `Postponement`, `PenaltyRule`. **Services:** `attendance/` 20, `payroll/` 37, `salary/` 4, `adjustments/` 5 |
| **4. Inventory & Purchasing** | `Product(+Barcode, Category, WarehouseSetting)`, `Warehouse(+Assignment, BranchSupply)`, `InventoryMovement`, `StockIssue` / `Transfer` / `Adjustment` / `Count` (+items, imports), `GoodsReceipt(+Item)`, `PurchaseRequest(+Item)`, `Supplier`, laundry (`TowelType`, `TowelTransfer`, `TowelLedgerEntry`, `TowelAdjustment`, `LaundryBatch(+Consumption)`, `LaundryStandardCostRate`). **Services:** `inventory/` 60, `laundry/` 9. **Controllers:** `inventory/` 21, `laundry/` 11 |
| **5. Finance & Sales** | `DailyReconciliation`, `TillSession(+Amount)`, `TillHandover(+Amount)`, `TillDeposit`, `TillRefund`, `RemainingDepositBalance(+Transaction)`, `DepositResponsibilityTransfer`, `DepositMatch`, `CustodyAccount` / `Transaction`, `Expense` (+allocation, category, type, tag), `RecurringExpense(+Allocation)`, `FinancialSettlement`, `FinancialAdjustment`, `BankStatement(+Transaction)`, `BankDispute`, `PaymentMethod`, `SalesImport` / `SalesTransaction`, `PosTerminal`, legacy `PosImport` / `PosTransaction`, `BranchRevenue`, `EmployeeReconciliationSummary(+Amount)`. **Services:** `finance/` 92, `financial_settlement_service`. **Controllers:** `finance/` 21, till handovers |
| **6. Reporting** | **Services:** `reports/` 4, `dashboard/` 3, cross-domain report readers (laundry cost summary, per `module-boundaries.md` §12) |

---

## 3. Candidate inventory

The candidates were chosen as independently movable components: a model, or a tightly related group with its own
controller, policy and services.

| # | Candidate | Domain | Own files (models, controllers, policies, views, services) |
|---|---|---|---|
| C1 | `UserAuditLog` | Organization & Access | 1 |
| C2 | Department + JobTitle catalogs | Workforce | 14 |
| C3 | BiometricDevice group (`BiometricDevice`, `BiometricPunchLog`, admin and API punch endpoints) | Attendance & Payroll | 9 |
| C4 | EmployeeDataRequest group (request, event, revision, 6 services, controller, policy, views) | Workforce | 18 |
| C5 | Performance evaluation group (reviews, scores, observations, templates, criteria; `performance/` controllers and services) | Workforce | 49 |
| C6 | ShiftTemplate group (`ShiftTemplate`, `ShiftTemplateEntry`, `scheduling/` services, admin controller) | Workforce | 14 |
| C7 | `Branch` (reference point for an upstream, highly coupled model) | Organization & Access | 15 |

---

## 4. Evidence and dependency analysis

**Measurement notes:**

* **External refs:** code lines in `app/` and `lib/` outside the candidate's own files that mention its constants
  or associations. Comment lines are ignored.
* **Domain split:** by file path. This is a heuristic, and some files are classified "other" (helpers, the sidebar).
* **Spec files:** files whose text mentions the candidate, so for broad names they include incidental users.
* **Data migrations:** migrations that *call* the constant in code. Comment-only mentions are excluded.

| | C1 UserAuditLog | C2 Dept + JobTitle | C3 Biometric | C4 EmployeeDataRequest | C5 Performance | C6 ShiftTemplate | C7 Branch |
|---|---|---|---|---|---|---|---|
| External files / lines | 2 / 2 | 27 / 74 | 13 / 61 | 2 / 5 | 14 / 66 | 7 / 15 | **262 / 998** |
| Split by domain (files) | Organization & Access 2 (password controllers) | Workforce 20, Organization & Access 5, Reporting 1, other 1 | Attendance & Payroll 8, Organization & Access 1, other 4 | Workforce 1, other 1 (sidebar) | Workforce 9, Organization & Access 4, other 1 | Workforce 6, other 1 | Finance & Sales 113, Inventory & Purchasing 58, Attendance & Payroll 47, Workforce 23, Reporting 8, Organization & Access 7, other 6 |
| Cross-domain reads | none | Organization & Access user screens and `User` read Workforce-stewarded `department` / `job_title` | `Business has_many` (Organization & Access → Attendance & Payroll inverse) | sidebar only | `User` / `Business has_many` (Organization & Access → Workforce inverse); admin users screens | none | every domain |
| Cross-domain writes | none | none | none | **Approval creates a `User`** (`EmployeeDataRequests::EmployeeAttributes` → `User.new`; `Reviewer` `employee.save!`) into the Organization & Access-owned `users` table (Workforce-stewarded columns) | none | none | branch form writes `pos_terminals` (Organization & Access → Finance & Sales, recorded violation) |
| Upward / circular edges | none | **`User#job_title_from_catalog` → `JobTitle.selectable?`** (Organization & Access model → Workforce; documented stewardship, `module-boundaries.md` §3.2) | none | User ≠ Employee boundary (account creation) | Organization & Access inverse `has_many` | none | **Organization & Access → Workforce** (`EmployeeScope` / `BranchScope` → `BranchMembership`; unresolved inversion, `module-boundaries.md` §12.2) |
| Security sensitivity | Password-change audit trail | Admin catalogs (`manage_settings` / `manage_employees` / `manage_evaluation_templates`) | **Device-token API ingress** (`Api::V1::PunchesController`, `Bearer <device_token>`); attendance feeds payroll | **Personal data and national-ID photos**; reviewer permissions; account creation | Human-resources evaluations, department-scoped | Bulk assignment creation | Branch scope underpins every access check |
| Business criticality | Medium (audit-first) | Low–medium | **High** (attendance → payroll) | Medium | Medium | Medium | High |
| Specs referencing / examples | 4 files (characterization and security); no model spec | 8 files / 191 examples; `admin/job_titles_spec`; **no departments request or policy spec found** | 11 files / 319 examples, including `api/v1/characterization/biometric_punch_spec` | 11 files / 160 examples (policy, services, request, system) | 7 files / 70 examples | 8 files / 213 examples | 322 files |
| Baseline failures in its specs | 0 | 0 in own specs (2 in the referencing `sidebar_active_state_spec`) | 0 | 0 | 0 | **11** (`template_applier_spec` ×10 — creates 0 assignments; `admin/shift_templates_spec` ×1) | many shared files |
| Tables / foreign keys in | `user_audit_logs` / 0 | `departments` (3 incoming FKs), `job_titles` (0); `users.department_id` plus legacy `users.department` string | `biometric_devices` (1), `biometric_punch_logs` (0) | 3 tables (2 + 0 + 1 incoming) | 5 tables (1 + 0 + 0 + 1 + 2 incoming) | 2 tables (2 incoming) | many |
| Stored class names (development) | none | none | none | **`active_storage_attachments.record_type = "EmployeeDataRequestRevision"` (4 rows)** | none | none | none |
| Data migrations calling the constant | 0 | 0 (one comment-only mention) | 0 | 0 | 0 (one comment-only mention) | 0 | **8** |
| Controller coupling | 2 password controllers | admin catalogs + performance controllers | admin punch logs + 2 API controllers | own controller | `performance/` 5 + admin evaluation templates | admin + shift assignments | everywhere |
| Needs the User ≠ Employee split? | No | No (columns stay; stewardship documented) | No | No for a move; **yes for a clean account-creation interface** | No | No | No |
| Touches a locked decision? | **D1-adjacent**: audit behaviour must stay as-is | No | No | No | No | No | No |

---

## 5. Scoring table

The weights come from `migration-pattern.md` §12. Each score is 1 (best) to 3 (worst), and the weighted total
ranges from 24 (best) to 72. The scores are judgments on the evidence in §4; the uncertain ones are marked `~`.

| Criterion (weight) | C1 UAL | C2 Dept/JT | C3 Biometric | C4 EDR | C5 Perf | C6 ShiftTpl | C7 Branch |
|---|---|---|---|---|---|---|---|
| Coupling (3) | 1 (2 files) | 2 (27 files) | 2 (13 files) | 1 (2 files) | 2 (14 files) | 1 (7 files) | 3 (262 files) |
| Callers (2) | 1 | 2 | 2 | 1 | 2 | 1 | 3 |
| Cross-domain edges / violations (3) | 1 (none) | 2 (Organization & Access reads + `User` validation edge) | 1 (one inverse `has_many`) | 2 (write into `users`) | 2 (inverse `has_many`) | 1 | 3 (all domains; recorded violations) |
| Security risk (3) | 2 (audit trail) | 1 | 3 (device-token API) | 3 (personal data / ID photos, account creation) | 2 | 1 | 3 |
| Business criticality (2) | 2 | 1 | 3 | 2 | 2 | 2 | 3 |
| Test coverage (2) | 2 (no model spec) | 2 (departments gap) | 1 (API characterized) | 1 | 2~ | 3 (core path failing) | 2~ |
| Database complexity (2) | 1 | 2 (users FK + legacy string) | 2 | 3 (stored `record_type`) | 2 (5 tables) | 2 | 3 (8 data migrations) |
| Circular-dependency risk (3) | 1 | 2 (`User` → `JobTitle`) | 1 | 2 (User ≠ Employee) | 2 | 1 | 3 (unresolved inversion) |
| Size (1) | 1 | 1 | 1 | 2 | 2 | 1 | 2 |
| Rollback difficulty (2) | 1 | 1 | 1 | 1 | 1 | 1 | 3 |
| Baseline noise (1) | 1 | 1 | 1 | 1 | 1 | 3 | 2~ |
| **Weighted total** | **31** | **39** | **41** | **43** | **45** | **34** | **68** |

C6 scores low but is disqualified (§6). The score alone is not sufficient.

---

## 6. Disqualifiers

| Disqualifier | C1 | C2 | C3 | C4 | C5 | C6 | C7 |
|---|---|---|---|---|---|---|---|
| Requires User/Employee architectural changes | no | no | no | no (move); **open** for a clean account-creation boundary | no | no | no |
| Unresolved circular dependency | no | no (edge documented as stewardship; see Q2) | no | no | no | no | **YES** (membership inversion) |
| No stable characterization possible | no | no | no | no | no | **YES** (core apply path failing) | no |
| Database isolation cannot be guaranteed | no | no | no | no | no | no | no |
| Touches an unresolved locked decision | no (D1 must simply be honoured) | no | no | no | no | no | no |
| Migration or schema change not understood | no | no | no | no | no | no | partly (8 data migrations) |
| Requires changing another domain first | no | no | no | no | no | no | **YES** (Workforce membership contract) |
| Known baseline failure blocks characterization | no | no | no | no | no | **YES** | no |
| **Result** | ELIGIBLE | ELIGIBLE | ELIGIBLE | ELIGIBLE | ELIGIBLE | **NOT ELIGIBLE** | **NOT ELIGIBLE** |

---

## 7. Dependency order

```
C1 UserAuditLog (Organization & Access)  ──► User (Organization & Access)                         [upstream-most]
C7 Branch (Organization & Access)        ◄── every domain;  ──► BranchMembership (Workforce)      [upstream; inversion pending]

C2 Department + JobTitle (Workforce)     ──► Business, User (Organization & Access)
          ▲  ◄── User#job_title_from_catalog (Organization & Access → Workforce, stewardship edge)
          │
          ├── C5 Performance group (Workforce)              ──► Department (Workforce); User, Business (Organization & Access)
          └── C4 EmployeeDataRequest group (Workforce)      ──► JobTitle, Department (Workforce); creates User (Organization & Access);
                                                                 PermissionCatalog (Organization & Access)
C6 ShiftTemplate group (Workforce)       ──► Shift, ShiftAssignment (Workforce); Branch (Organization & Access)

C3 BiometricDevice group (Attendance & Payroll) ──► Business (Organization & Access); attendance services (Attendance & Payroll)
```

* **Upstream:** C1 and C7 (Organization & Access); C2 (upstream *within* Workforce: C4 and C5 depend on it).
* **Downstream:** C4 and C5 (after C2); C3 (Attendance & Payroll, after Workforce in `module-boundaries.md` §19, but
  it depends only on Organization & Access and its own domain).

---

## 8. Shortlisted candidates — RECOMMENDED FOR REVIEW

| Candidate | Domain | Evidence | Main dependencies | Security risk | Test coverage | DB complexity | Main risk | Score | Eligible? |
|---|---|---|---|---|---|---|---|---|---|
| C1 UserAuditLog | Organization & Access | 1 file; 2 callers (password controllers) | `User` | Medium (audit) | Indirect only (4 specs) | Low | Little to learn: only M0, M1, M6, M7 apply | 31 | **RECOMMENDED FOR REVIEW** |
| C2 Department + JobTitle | Workforce | 14 files; 27 external files, mostly Workforce | `Business`, `User` | Low | 191 examples; departments gap | Medium (`users` FK + legacy string) | `User` → `JobTitle` validation edge | 39 | **RECOMMENDED FOR REVIEW** |
| C3 BiometricDevice group | Attendance & Payroll | 9 files; 13 external files, mostly Attendance & Payroll | `Business`, attendance services | **High** (device API) | 319 examples, API characterized | Medium | Device-auth regression | 41 | **RECOMMENDED FOR REVIEW** |
| C4 EmployeeDataRequest | Workforce | 18 files; 2 external files | JobTitle, Department, `User` creation | **High** (personal data) | 160 examples | **High** (stored `record_type`) | Cross-domain account creation | 43 | ELIGIBLE |
| C5 Performance group | Workforce | 49 files; 14 external files | Department, `User`, `Business` | Medium | 70 examples | Medium | Size; inverse associations | 45 | ELIGIBLE |
| C6 ShiftTemplate group | Workforce | 14 files; 7 external files | Shift, ShiftAssignment, Branch | Low | 213 examples, **core failing** | Medium | Baseline-broken behaviour | 34 | NOT ELIGIBLE |
| C7 Branch | Organization & Access | 262 external files | every domain | High | broad | High | Coupling, inversion, data migrations | 68 | NOT ELIGIBLE |

### C1 — UserAuditLog (Organization & Access)

* **Why realistic:** the smallest eligible component. It has 2 callers, both inside Organization & Access, no data
  migrations calling it, and no stored class names.
* **Smaller or safer because:** there are no cross-domain callers, so M2/M3 are not needed. The likely steps are a
  location move (M7) and enforcement (M6).
* **Before implementation:** M1 characterization of the two writers (self password change, admin reset) already
  exists in `account_management_spec`; decide whether a model spec is needed for the `ACTIONS` validation.
* **Reasons to reject:** it validates almost nothing new beyond the PermissionRole pilot. It is better treated as an
  Organization & Access close-out item than as the next *pilot*. Also, D1 (role-change auditing out of scope) makes
  audit-adjacent changes sensitive.

### C2 — Department + JobTitle catalogs (Workforce)

* **Why realistic:** the first Workforce component, in dependency order (Organization & Access → Workforce). It is
  upstream within Workforce (Performance and onboarding consume it), and catalog-like, much like the
  PermissionRole catalogue. It has no data migrations calling it and no stored class names.
* **Smaller or safer because:**
  * Low security risk (admin catalogs).
  * 0 baseline failures in its own specs.
  * Most callers are in the same domain; cross-domain readers are a few Organization & Access user screens and
    `User`.
* **Before implementation:**
  * Fill the **departments characterization gap** (no departments request or policy spec found).
  * Record a decision on the `User#job_title_from_catalog` edge: keep it as documented Workforce stewardship on the
    shared `users` table, or route it through a Workforce interface (Q2).
  * Keep the legacy `users.department` string out of scope.
* **Reasons to reject:** if the reviewer decides the `User` → `JobTitle` edge must become an interface first; that
  touches `User` (Organization & Access), which the pilot rules avoid.

### C3 — BiometricDevice group (Attendance & Payroll)

* **Why realistic:** small (9 own files), callers almost entirely within Attendance & Payroll, the strongest
  coverage of the shortlist (319 examples including the characterized punch API), 0 baseline failures, no data
  migrations calling it, and no stored class names.
* **Smaller or safer because:** it has no cross-domain writes, and its only cross-domain edge is the
  Organization & Access `Business has_many` inverse.
* **Before implementation:**
  * Confirm that the device-token API characterization covers invalid tokens, inactive devices and cross-business
    devices; add gaps only if needed.
  * Record the decision to leave the `Business` inverse association as a recorded exception.
* **Reasons to reject:**
  * High security and business criticality: an authentication path for external hardware that feeds payroll.
  * It precedes Workforce in practice, although `module-boundaries.md` §19 orders Attendance & Payroll after
    Workforce (allowed, because it does not depend on Workforce, but it is a deviation the reviewer must accept).

---

## 9. Preconditions (only what each candidate actually needs)

| Precondition | C1 UserAuditLog | C2 Dept + JobTitle | C3 Biometric |
|---|---|---|---|
| M0 inventory + baseline failing-ID capture | Required | Required | Required |
| Decision records | Confirm D1 is unaffected | `User` → `JobTitle` edge (Q2); legacy `users.department` out of scope | `Business` inverse `has_many` stays as an exception |
| Characterization (M1) | Minimal (writers covered); optional `ACTIONS` model spec | **Departments** request and policy specs; `JobTitle.selectable?` contract | Device-token negative cases if missing; punch payload contract |
| Security tests | Existing password and audit specs | Admin catalog authorization (`manage_settings` / `manage_employees` / `manage_evaluation_templates`) | **Device authentication** and cross-business device isolation |
| Boundary / read routing (M2–M3) | Not needed (no cross-domain callers) | Only if Q2 decides on an interface for Organization & Access readers | Not needed (only the inverse association) |
| Database verification (M8) | Not needed (no migration calls the constant; nothing stored) | Not needed (same) | Not needed (same) |
| Physical move (M7) | Optional | Optional (collapsed `app/models/workforce/`) | Optional (collapsed `app/models/attendance_payroll/`, naming to confirm) |

---

## 10. Open questions

| # | Question |
|---|---|
| Q1 | Should the next pilot prioritise **lowest risk** (C1) or **advancing the dependency order** into Workforce (C2)? |
| Q2 | Is `User#job_title_from_catalog` → `JobTitle` accepted as documented Workforce stewardship on the shared `users` table (no interface), or must it become a Workforce interface before C2? |
| Q3 | Is migrating an Attendance & Payroll component (C3) before any Workforce component acceptable under `module-boundaries.md` §19? |
| Q4 | Folder and namespace names for Workforce and Attendance & Payroll (`app/models/workforce/`, `Workforce::`; `attendance_payroll` vs another name) need confirming before any M7. |
| Q5 | **C6 ShiftTemplate:** should the 11 baseline failures (`TemplateApplier` creating 0 assignments) be triaged as a separate bug task? It cannot be a pilot until its core path is characterizable. |
| Q6 | **C4 EmployeeDataRequest:** before it is piloted, who owns account creation on approval (an Organization & Access interface vs the current Workforce write into `users`)? |
| Q7 | **C7 Branch:** remains blocked until the Workforce membership contract (`module-boundaries.md` §12.1 inversion) is designed. |

---

## 11. Statement

**No pilot has been selected.** This document classifies candidates as RECOMMENDED FOR REVIEW, ELIGIBLE or NOT
ELIGIBLE only. Selection, and any implementation, require a separate explicit decision.

---

## Decision Review

**Status:** READ-ONLY decision analysis (at `c1aac8b`). Nothing is selected or implemented. The evidence was
re-verified against the repository, plus one rolled-back test-environment probe (Q7).

### 1. UserAuditLog vs Department + JobTitle (Q1)

| Aspect | A. `UserAuditLog` | B. Department + JobTitle |
|---|---|---|
| **Architectural learning** | How the collapsed-model convention applies to a second Organization & Access model. Nothing about a new domain | First **Workforce** component: establishes the Workforce location/namespace convention (§4), the first cross-domain read routing **into** Workforce, and the Organization & Access ↔ Workforce stewardship rule on the shared `users` table |
| **Pattern exercised** | M0, M1 (minimal), M6, M7. M2/M3/M5 do not apply (no cross-domain callers, no controller logic) | M0, M1 (fills a real gap), M2/M3 (Organization & Access screens and Performance read catalogues), M6, and optionally M7. M5 only if catalog CRUD rules sit in controllers (to confirm in M0) |
| **Coupling** | 2 external files, both Organization & Access (`profile/passwords_controller`, `admin/user_passwords_controller`) | 27 external files / 74 lines. Workforce 20, Organization & Access 5 (`user.rb`, `business.rb`, `admin/users` form/show, `admin/users_controller`), Reporting 1 |
| **Cross-domain boundaries** | None | Organization & Access screens read Workforce catalogues; `User#job_title_from_catalog` → `JobTitle.selectable?` (§2) |
| **Security sensitivity** | Audit trail of password changes, and adjacent to D1 (audit behaviour is a locked decision) | Low: admin catalogues gated by `manage_settings` / `manage_employees` / `manage_evaluation_templates` |
| **Test coverage** | No model spec; covered indirectly by 4 characterization and security specs | 191 examples reference it; `admin/job_titles_spec` exists; **no departments request or policy spec** (a real M1 gap); 0 baseline failures in its own specs |
| **Rollback complexity** | Trivial (single file) | Low: catalog models, no data migration calls them, no stored class names; each step is one `git revert` |
| **Representative of future migrations?** | No. Most remaining components have cross-domain callers | Yes. Catalogue consumed by its own domain plus upstream screens, as is typical for Workforce, Attendance & Payroll and Inventory & Purchasing reference data |

**Conclusion for review:** **B (Department + JobTitle)** is the more suitable candidate for review as the next *real
domain* migration pilot. A (`UserAuditLog`) is lower risk but validates little that PermissionRole did not; it is
better handled later as an Organization & Access close-out item.

### 2. User → JobTitle dependency analysis (Q2)

**Exact code:**

* `app/models/user.rb:126` declares `validate :job_title_from_catalog, if: :will_save_change_to_job_title?`.
* `app/models/user.rb:300–304` defines the method. It returns early when `job_title` or `business_id` is blank,
  otherwise adds `errors.add(:job_title, :not_in_list) unless JobTitle.selectable?(business_id, job_title)`.
* `app/models/job_title.rb` defines `JobTitle.selectable?(business_id, name)`: an active title of the business,
  matched case-insensitively. `JobTitle.options_for(business, current:)` feeds the dropdown
  (`app/views/shared/_job_title_select.html.erb`, used by the employee form and employee data requests).
* **Storage:** `users.job_title` is a **string**, the chosen name; there is no foreign key to `job_titles`.
  Departments, by contrast, link via the foreign key `users.department_id` (`User belongs_to :department, optional`),
  plus a legacy `users.department` string.

**Nature of the dependency:**

* **What it is:** a **validation lookup**. It is not ownership and not business logic beyond membership: "a newly
  set or changed job title must be an active catalogue entry". Unchanged legacy values are left alone.
* **Why `User` performs it:** Employee profile attributes live on the shared `users` table, and the Employee concept
  has no separate model (§6). So the Employee rule is attached to the physical `User` class.
* **Data ownership:** `JobTitle` owns the catalogue rows (`job_titles`). The **value** in `users.job_title` is an
  Employee attribute under Workforce stewardship (`module-boundaries.md` §3.2), and §10.1 names this exact method as
  JobTitle's consumer.

**Is a Workforce interface necessary?**

* **No.** The rule is a Workforce rule on a Workforce-stewarded column. It runs inside the `users` record's save, and
  the only collaborator is Workforce's own catalogue.
* An interface (for example `Workforce::JobTitles.selectable?`) would **add a layer without removing any coupling**.
  `User` would still call Workforce, just through one more name. That is the "wrapper for an internal rule" the
  pattern warns against (`migration-pattern.md` §5 H, §11).
* **Keeping it temporarily is acceptable** under the pattern (§5 rule I: stewardship on the shared table is
  documented). It must be:
  * pinned in M1 (`JobTitle.selectable?` contract; `User` rejects an inactive or unknown title, accepts an active
    one, ignores unchanged legacy values)
  * allow-listed **with its reason** in the future Workforce boundary spec
* It would only need to move if the User ≠ Employee split is ever implemented. That is explicitly out of scope.

### 3. Domain ownership confirmation (Q3)

| Item | Owner of data | Who may validate | Who may read |
|---|---|---|---|
| `departments` rows (`Department`) | **Workforce** | Workforce (`Department` model, `DepartmentPolicy`) | Workforce (Performance templates/reviews, analytics); Organization & Access employee screens and Reporting via Workforce read paths |
| `job_titles` rows (`JobTitle`) | **Workforce** | Workforce (`JobTitle`, `JobTitlePolicy`) | Workforce (onboarding, employee form partial); Organization & Access employee screens via `JobTitle.options_for` |
| `users.job_title` (string) | **Workforce stewardship** on the Organization & Access-owned `users` table (§3.2) | Workforce rule `User#job_title_from_catalog` (physically in `User`) | Any domain may read the employee's title |
| `users.department_id` (+ legacy `users.department` string) and `User belongs_to :department` | **Workforce stewardship** on `users` (§3.2) | Workforce | Any domain may read; Performance uses it for scoping |
| `users` table itself, account fields (login, password, `active`, `permission_role`, `business_id`) | **Organization & Access** | Organization & Access | Via Organization & Access interfaces (`User#can?`, …) |
| `Business has_many :departments / :job_titles` | Inverse associations on an Organization & Access model, pointing into Workforce | — | Recorded inverse association, same class as the `PermissionRole` and Biometric inverses; it stays as a documented exception during the pilot |

**User ≠ Employee:** the Employee is a **concept**. There is no `Employee` model or `employees` table: it was
dropped in `20260507000006_drop_employees_table`. Its attributes are Workforce-stewarded columns on `users`. Nothing
here requires redesigning `User` or Employee.

### 4. Workforce target structure (Q4)

**Repository facts:**

* Workforce services already live in **several sub-area namespaces**: `Shifts::` (`app/services/shifts/`),
  `Scheduling::`, `Performance::`, `EmployeeDataRequests::`, `Requests::` and `Employee::`. `Employee::` holds
  `PerformanceScorer` and `InsuranceProfileUpdater`, and is also called from `Payroll::RecommendationEngine` and the
  operations dashboard.
* Controllers: `performance/` namespace plus top-level `shifts`, `shift_assignments`, `employee_requests`,
  `employee_data_requests`, and `admin/departments`, `admin/job_titles`, `admin/shift_templates`.
* **No `Workforce` constant exists** in code; 4 mentions, all in comments.

**Proposed convention** (naming only; nothing is created):

| Purpose | Location | Constant |
|---|---|---|
| Cross-domain boundary (public interfaces other domains call) | `app/services/workforce/` | `Workforce::` (like `OrganizationAccess::`) |
| Workforce models, when moved (M7, optional) | `app/models/workforce/`, **collapsed** (one initializer line, like `organization_access_autoload.rb`) | **Top-level** (`Department`, `JobTitle`) |
| Existing sub-area namespaces | Unchanged (`Shifts::`, `Scheduling::`, `Performance::`, `EmployeeDataRequests::`, `Requests::`, `Employee::`) | Internal to Workforce; **not renamed** (renaming them is not needed for ownership and would be a large, risky move) |

* **Do not use `Employee` as the domain namespace:** `Employee::` is already a services namespace, and the domain is
  "Workforce".
* Controllers and views stay where they are (routes unchanged).

### 5. BiometricDevice risk explanation (Q5)

**Dependencies:**

* `Api::V1::PunchesController < BiometricBaseController` authenticates the **device** (`Authorization: Bearer
  <device_token>` or `X-Device-Token`) and resolves `current_business` from the device.
* It finds the employee with `current_business.users.active`, then calls `Attendance::PunchService`.
* `PunchService` writes `AttendanceRecord` (`find_or_initialize_by(user, work_date)`; check-in/check-out updates).
* `Attendance::AnomalyDetector` and `Attendance::TimestampParser` consume it.
* `Business has_many :biometric_devices / :biometric_punch_logs` (Organization & Access inverse).

**Security sensitivity:** an external-hardware authentication realm, separate from web sessions. The
characterization pins:

* 401 without a token
* 401 for an inactive device
* the `X-Device-Token` alternative
* web sessions ignored
* the success payload
* 404 for an employee outside the device's business
* 422 for an invalid timestamp, for a timestamp outside the 24-hour window, and for an employee not allowed
  biometric attendance

**Payroll impact:** punches create or adjust `AttendanceRecord` check-in/check-out and lateness, which feed payroll
(overtime, deductions). A regression would silently change pay.

**Characterization coverage:** strong (9 API characterization examples above, plus `punch_service`,
`anomaly_detector`, `timestamp_parser` and admin punch-log specs; 319 examples reference it; 0 baseline failures).

**Why it ranks after Department + JobTitle:**

* Higher security (device authentication) and business criticality (payroll), scored 3/3 on both.
* It belongs to Attendance & Payroll, which `module-boundaries.md` §19 orders after Workforce.
* A pilot there would teach the pattern on the riskiest kind of path first.

**Additional safety net before it could be a pilot:**

* Device-token edge cases beyond the 9: an unknown token (vs inactive), a token of a device in another business,
  replay or duplicate punches (idempotency of the same timestamp).
* `PunchService` outcome contracts per branch: earlier punch, later punch, stale.
* Lateness recalculation pinned against payroll-relevant fields.
* A baseline capture of the attendance/payroll spec area.

### 6. Onboarding ownership analysis (Q6)

**Actual code path:**

1. `EmployeeDataRequests::Reviewer.approve(request_id:, actor:, …)` loads the request, applies corrections, checks
   identity conflicts (`User.where(identity_card_number: …)` / `phone_number`), then calls `build_employee`.
2. `build_employee` calls `EmployeeAttributes.build_user(revision, business_id:)` → `User.new(...)`. The whitelist is
   personal and basic data only, including `job_title`. It has **no** branch, salary, role, permissions or password.
   The ID photos are copied.
3. `employee.save!` runs inside the transaction (this runs `User#job_title_from_catalog`), followed by `log_audit`
   `employee.created_from_data_request`.
4. The **account** is not activated here. The new `User` has no password and no role. Account claim happens later
   through the Organization & Access invitation flow (OA-S6, `generates_token_for(:account_claim)`), and roles are
   assigned via `OrganizationAccess::RoleAssignmentRule`.

**Who owns what:**

* **Employee creation:** **Workforce** (the onboarding lifecycle, `EmployeeAttributes` whitelist; Workforce-stewarded
  columns on `users`).
* **Account creation and activation:** **Organization & Access**. The invitation and claim set the password and
  activate login; Organization & Access assigns roles.
* **Employee record:** the same `users` row serves as both (User ≠ Employee is conceptual). There is no separate
  `Employee` model to create.

**Relevance to Department + JobTitle:**

* Onboarding is a **consumer** of JobTitle: the dropdown via `JobTitle.options_for`, and the save validated by
  `User#job_title_from_catalog`.
* It does **not** block the pilot. It only requires that the `JobTitle.options_for` / `selectable?` contracts stay
  stable, which M1 will pin.
* The account-creation ownership question matters for a future **EmployeeDataRequest** pilot (C4), not for C2.

### 7. ShiftTemplate baseline assessment (Q7)

* **Failures (reproduced):** `spec/services/scheduling/template_applier_spec.rb` lines 33, 37, 45, 51, 57, 89, 93,
  102, 107, 127, and `spec/requests/admin/shift_templates_spec.rb:204`. That is 11 of 32 examples, all deterministic.
* **Root cause:**
  * Commit `aa5d5e5` changed `ShiftAssignment` from `belongs_to :branch, optional: true` to `belongs_to :branch`
    (required, message "Branch must be selected").
  * `ShiftTemplateEntry` still has `belongs_to :branch, optional: true`, and its specs build entries with
    `branch: nil`.
  * `Scheduling::TemplateApplier` therefore records a row error instead of creating the assignment. The probe
    confirmed `ShiftAssignment.new(…, branch: nil).valid? == false` with `["Branch must be selected"]`, run in a
    rolled-back transaction in the test environment.
  * The same change explains the baseline failure `spec/models/shift_assignment_spec.rb:7`
    (`belong_to(:branch).optional`).
* **Does it prevent characterization?** Yes, for the template-apply path. The specs and the model disagree about
  intended behaviour: should branch-less template entries be applied, or rejected? That is a product decision, so
  there is no stable contract to pin until it is made.
* **Does it prevent a safe future pilot?** Yes, until it is decided and fixed in a separate task. It is unrelated to
  Department + JobTitle.
* **Track as technical debt:** **TD-ST1.** Inconsistent branch requirement between `ShiftTemplateEntry` (optional)
  and `ShiftAssignment` (required since `aa5d5e5`). The template apply path silently produces row errors for
  branch-less entries, and 12 baseline failures stem from it. Not to be fixed within any migration pilot.

### 8. Recommended decision to take next

For the reviewer to decide (nothing is selected yet):

1. **Choose Department + JobTitle (C2) for review as the next pilot.** It is representative of Workforce, low
   security risk, has no database phase, and is first in dependency order.
2. **Record decision D-WF1:** `User#job_title_from_catalog` stays in `User` as documented Workforce stewardship on
   the shared `users` table. No interface. Pinned in M1 and allow-listed in the Workforce boundary spec.
3. **Record decision D-WF2 (structure):**
   * `Workforce::` boundary in `app/services/workforce/`
   * optional collapsed `app/models/workforce/` with top-level constants
   * existing sub-area namespaces unchanged
   * no `Employee` domain namespace
4. **Record out-of-scope items:**
   * the legacy `users.department` string column
   * `Business has_many :departments / :job_titles` inverses (documented exception)
   * onboarding account-creation ownership (relevant to a future C4 pilot only)
5. **Open separate technical-debt items:** **TD-ST1** (ShiftTemplate branch requirement); BiometricDevice
   safety-net additions only if it is selected later.
6. Only after these decisions: start the pilot at **M0** (inventory + baseline failing-ID capture), then **M1**
   (departments request/policy specs; `JobTitle.selectable?` / `options_for` contracts; the `User` title
   validation).

---

## Selected pilot and locked decisions

**NEXT PILOT = Department + JobTitle.** This is the second migration pilot and the first Workforce pilot, selected
after the Decision Review.

| ID | Decision |
|---|---|
| **D-WF1** | **Keep the existing `User` → `JobTitle` validation (`User#job_title_from_catalog` → `JobTitle.selectable?`) in `User` for this pilot.** It is a Workforce-owned rule operating on the shared `users` table. A Workforce interface would add coupling without removing the dependency. It is an explicit, temporary boundary exception, and `User` is not modified by the pilot |
| **D-WF2** | **Workforce structure convention:** `app/services/workforce/` holds Workforce public boundaries/interfaces (`Workforce::`). `app/models/workforce/` holds Workforce-owned models when a physical move is appropriate, using the PermissionRole collapsed-folder approach so models stay top-level constants. **Folders are not created yet** |

**Pilot scope:** only `Department`, `JobTitle`, their direct business rules, direct tests, and direct boundary or
cross-domain usage.

**Excluded:** Employee, User redesign, EmployeeDataRequest migration, Scheduling, ShiftTemplate, BiometricDevice,
Attendance, Payroll, Performance, Branch, Organization & Access migration, Reporting migration and Booking. The
D-WF1 exception is the only allowed `User` touch point.

---

## Department + JobTitle — M0 Inventory

**Status:** M0 COMPLETE (read-only inventory and baseline at `c1aac8b`; no production or test change).

### 1. Scope

`Department` (`app/models/department.rb`, table `departments`) and `JobTitle` (`app/models/job_title.rb`, table
`job_titles`): models, admin controllers, policies, views, routes, factories, seeds, and every direct reference
from other code.

### 2. Complete reference inventory

These are code lines; comment lines are ignored. **54 files** in `app/` (including one stylesheet and one
Stimulus controller), `config/routes.rb` and `db/seeds.rb` reference them, and the categories below cover every one.

| Category | References |
|---|---|
| **Models** | `Department`: `belongs_to :business`; `has_many :users, dependent: :nullify`; `has_many :evaluation_templates` and `:performance_reviews, dependent: :restrict_with_error`; `normalizes :name` (trim + collapse whitespace); name presence, max 100, unique per business (case-insensitive); scopes `active` / `ordered` / `for_business`; `deactivate!` / `activate!`. `JobTitle`: `belongs_to :business`; same normalization and validations; scopes `active` / `ordered` / `for_business`; class methods **`options_for(business, current:)`** (active ordered names, plus the current value if it is no longer active) and **`selectable?(business_id, name)`** (active, case-insensitive) |
| **Controllers** | `Admin::DepartmentsController` (index/new/create/edit/update/destroy; destroy → alert with model errors when restricted). `Admin::JobTitlesController` (index/new/create/edit/update; **no destroy**, deactivation only; index computes `@employee_counts` from `users.job_title`). Both inherit `Admin::BaseController` |
| **API controllers** | None |
| **Policies** | `DepartmentPolicy` (all actions: `manage_evaluation_templates` or `manage_settings`; Scope `for_business(user.business)`). `JobTitlePolicy` (index/create/update: `manage_employees` or `manage_settings`; same Scope). `UserPolicy::EMPLOYMENT_ATTRIBUTES` includes `job_title`, `department_id` |
| **Services / queries** | Workforce Performance only: `Performance::Analytics`, `Performance::ReviewAnalytics` (`Department.where(id:).pluck`), `Performance::ReviewComposer`, `Performance::Exports::{EmployeeSummaryWorkbook,ReviewsWorkbook}`. Onboarding: `EmployeeDataRequests::EmployeeAttributes` maps `job_title` |
| **Serializers / presenters / jobs / concerns** | None |
| **Callbacks** | `PerformanceReview before_validation :snapshot_branch_and_department` (copies `employee.department_id`). `PerformanceObservation` validates criterion department = employee department. `User` validation `job_title_from_catalog` (D-WF1) |
| **Helpers / views** | `admin/departments/*` (4), `admin/job_titles/*` (4); `shared/_job_title_select` (`JobTitle.options_for`; used by the employee form and onboarding `_data_fields`); `admin/users/_form` (department select, keeping an inactive current department) and `admin/users/show`; `admin/evaluation_templates/*`; `performance/*` views (filters, rankings, forms); `layouts/_sidebar` (`policy(Department/JobTitle).index?` + nav links); `observation_form_controller.js` and `application.css` (UI wording only) |
| **Routes** | `resources :departments, except: [:show]`; `resources :job_titles, only: [:index, :new, :create, :edit, :update]` (admin namespace) |
| **Factories / seeds** | `spec/factories/departments.rb`, `spec/factories/job_titles.rb`; also used in the `employee_data_requests` and `performance_reviews` factories. `db/seeds.rb` `seed_department` (normalized find-or-create) |
| **Locales** | `admin.departments.*`, `admin.job_titles.*`, `job_titles.*`, `nav.job_titles` (en + ar) |

### 3. Internal vs cross-domain classification

| Reference | Classification | Reason |
|---|---|---|
| Models, admin controllers, policies, views, routes, factories, seeds | **INTERNAL TO WORKFORCE** | Owned by Workforce (`module-boundaries.md` §5, §10) |
| `Performance::*` services, performance controllers and views, `EvaluationTemplate` / `PerformanceReview` / `PerformanceObservation` / `EvaluationCriterion` associations and callbacks | **INTERNAL TO WORKFORCE** | Performance is a Workforce sub-area (§5) |
| `EmployeeDataRequests::EmployeeAttributes`, onboarding `_data_fields` (job-title select) | **INTERNAL TO WORKFORCE** | Onboarding is Workforce (§5) |
| `admin/users/_form`, `admin/users/show`, `Admin::UsersController` `includes(:department)`, `UserPolicy::EMPLOYMENT_ATTRIBUTES` | **INTERNAL TO WORKFORCE (by ownership)** | These are the **Employee part** of `admin/users`, assigned to Workforce in §5. They currently live in Organization & Access-shared files |
| `User belongs_to :department`; `User#job_title_from_catalog` → `JobTitle.selectable?`; `PROFILE_COMPLETION_FIELDS` (`:job_title`, `:department`); `scope :by_department` | **CROSS-DOMAIN DEPENDENCY** (physical Organization & Access model, Workforce-stewarded columns) | Allowed under D-WF1 and `module-boundaries.md` §3.2 stewardship |
| `Business has_many :departments / :job_titles` | **CROSS-DOMAIN DEPENDENCY** (Organization & Access → Workforce inverse) | Recorded inverse association; documented exception |
| `layouts/_sidebar` (policy checks + nav) | **CROSS-DOMAIN DEPENDENCY** (UI shell / infrastructure) | Navigation shell; reads policies only |
| `Admin::BaseController` gate (`manage_evaluation_templates`, `manage_employees`, `manage_settings` admit admin access) | **CROSS-DOMAIN DEPENDENCY** (Organization & Access infrastructure) | Both admin controllers inherit the Organization & Access admin gate |
| Reporting, Attendance & Payroll, Finance & Sales, Inventory & Purchasing, API | **None** | Verified: no references in `app/services/{reports,dashboard,payroll,finance,inventory,attendance}`, `app/controllers/{finance,inventory,api}`, or the dashboard / operations dashboard controllers |

**Key finding:** there are **no cross-domain read callers** that use the catalogues through code (no other domain
calls `Department` / `JobTitle` methods). The only cross-domain touch points are the shared `User` / `Business`
models (stewardship and inverse associations), the sidebar shell and the admin gate.

### 4. Dependency map

```
Organization & Access (physical models / infrastructure)
  User ──belongs_to──► Department          (users.department_id, FK)
  User ──validation──► JobTitle.selectable? (D-WF1; users.job_title string)
  Business ──has_many──► Department, JobTitle (inverse, dependent: :destroy)
  Admin::BaseController gate ──► Admin::DepartmentsController, Admin::JobTitlesController
  layouts/_sidebar ──policy──► DepartmentPolicy, JobTitlePolicy

Workforce (internal)
  Department ◄── EvaluationTemplate (FK, restrict), PerformanceReview (FK, restrict, snapshot),
                 PerformanceObservation (department consistency), Performance::* analytics/exports
  JobTitle   ◄── shared/_job_title_select (employee form, onboarding), EmployeeAttributes
```

There are no circular dependencies beyond the documented stewardship edge (D-WF1).

### 5. Database analysis

| Item | Finding |
|---|---|
| Tables | `departments` (`active`, `business_id`, `name`, timestamps); `job_titles` (same columns) |
| Indexes | Each table: unique `(business_id, lower(name))`, plus `business_id` |
| Foreign keys | `departments → businesses`; `job_titles → businesses`; **into `departments`:** `users.department_id`, `evaluation_templates.department_id`, `performance_reviews.department_id`; **into `job_titles`: none** (`users.job_title` is a string) |
| `users` columns | `department_id` (FK, indexed), legacy `department` string (indexed with `business_id`), `job_title` string |
| Migrations mentioning them | 5: `20260612110000_create_departments_and_add_to_users`, `20260612110001_backfill_departments_from_users`, `20260612110002_create_evaluation_templates_and_criteria`, `20260612110003_create_performance_reviews_scores_and_observations`, `20260929180000_create_job_titles` |
| Migrations instantiating the models | **0.** The backfill uses SQL; `Department` and `JobTitle` appear only in comments and `say` text |
| Stored class names | **None** (no STI; no polymorphic or Active Storage `*_type` values for these classes) |
| Conclusion | **No database migration is required**, and no M8 database verification is needed for a collapsed-folder move |

**Existing ambiguity (record only, out of scope):** `users` has both a legacy `department` **string** column and a
`belongs_to :department` association, so the association reader shadows the column. `scope :by_department`
(`where(department: dept)`) has **0 callers**. `PROFILE_COMPLETION_FIELDS` uses `:department` (the association).
Tracked as **TD-WF1**.

### 6. Test inventory

| Behaviour | Specs | Status |
|---|---|---|
| `User` → `JobTitle` validation (D-WF1): accept active title, reject unknown, reject another business's or inactive title, keep unchanged legacy title, allow blank | `spec/models/user_job_title_spec.rb` (5) | **SAFE** |
| JobTitle admin: list/create/deactivate, case-insensitive duplicates, authorization denial, business isolation | `spec/requests/admin/job_titles_spec.rb` (4) | **SAFE** (partial: no rename/`employee_counts` example) |
| `JobTitle.options_for` / `.selectable?` contracts (consumed by the employee form, onboarding and `User`) | indirect only (through `user_job_title_spec`, onboarding specs) | **PARTIAL** |
| `JobTitle` model normalization / uniqueness | indirect (request duplicates example) | **PARTIAL** |
| `Department` model (normalization, uniqueness, scopes, `deactivate!` / `activate!`, `restrict_with_error`, `nullify`) | none | **MISSING** |
| Department admin (index isolation, create, update, destroy, blocked destroy, authorization) | none | **MISSING** |
| `DepartmentPolicy` / `JobTitlePolicy` | none (JobTitle denial covered by its request spec) | **MISSING** (Department) / **PARTIAL** (JobTitle) |
| Department in Performance (snapshot, consistency, analytics) | `performance_review_spec`, `performance/*` request and service specs | **PARTIAL** (Performance is out of scope; consumer behaviour only) |
| Employee form department / job-title selects (`admin/users`) | `admin/users_spec` (no dedicated department/title examples found) | **PARTIAL** |
| Onboarding job title | `employee_data_requests_spec`, `reviewer_spec` | **SAFE** for the consumer path |

### 7. Baseline results

**Command (relevant set, at `c1aac8b`):**

```
bundle exec rspec spec/models/user_job_title_spec.rb spec/models/user_spec.rb spec/models/performance_review_spec.rb \
  spec/requests/admin/job_titles_spec.rb spec/requests/admin/users_spec.rb spec/requests/employee_data_requests_spec.rb \
  spec/requests/performance spec/requests/sidebar_active_state_spec.rb spec/services/employee_data_requests \
  spec/services/performance spec/policies/employee_data_request_policy_spec.rb spec/policies/user_policy_spec.rb \
  spec/architecture
```

| Run | Examples | Failures | Pending | Failing IDs |
|---|---|---|---|---|
| Initial | 319 | 3 | 0 | `sidebar_active_state_spec.rb:215`, `:293`, `performance/reviews_analytics_spec.rb:38` |
| `:38` alone ×6 | 1 each | 0 | 0 | — (flaky confirmed) |
| Re-run 1 (after recording) | 319 | 2 | 0 | `sidebar_active_state_spec.rb:215`, `:293` |
| Re-run 2 | 319 | 2 | 0 | `sidebar_active_state_spec.rb:215`, `:293` |

* **Baseline file:** `docs/architecture/department-job-title-baseline-failures.txt`. It holds the 2 deterministic
  IDs (also in the PermissionRole full-suite baseline) and the TD-PERF1 flaky IDs, marked `flaky`.
* **No new failures.**

**TD-PERF1:** pre-existing, **flaky**, not caused by migration work, not fixed in this pilot.

* `spec/requests/performance/reviews_analytics_spec.rb:38` expects `employee.full_name` in plain text.
* Faker can generate a name with an apostrophe (observed: `Fatimah O'Conner`).
* The rendered HTML escapes the apostrophe as `&#39;`, so the plain-text expectation fails depending on the
  generated data.
* The example passed on 6 isolated reruns and on both full re-runs, which confirms it is flaky rather than
  deterministic.
* Lines 29 and 91 of the same file use the same pattern and carry the same risk; they are recorded as flaky too.

### 8. Characterization gaps (minimum before M1)

| # | Gap | Class | Why |
|---|---|---|---|
| DJ1 | **`Department` model contract:** name normalization and per-business case-insensitive uniqueness; `active` / `ordered` / `for_business`; `deactivate!` / `activate!`; `restrict_with_error` when templates or reviews exist; `nullify` users on destroy | **REQUIRED** | No coverage; a later physical move or boundary must not change it |
| DJ2 | **Department admin request flow:** index lists only this business; create/update; destroy succeeds without dependents; blocked destroy redirects with the model error alert; authorization (`manage_evaluation_templates` or `manage_settings`, otherwise denied); another business's department → 404 | **REQUIRED** | No coverage; security (authorization + business isolation) |
| DJ3 | **`JobTitle.options_for` / `.selectable?` contract:** active, ordered, business-scoped; current inactive value prepended, case-insensitive match; `selectable?` false for inactive, foreign, unknown | **REQUIRED** | Cross-domain contract consumed by `User` (D-WF1), the employee form and onboarding; currently only indirect |
| DJ4 | `JobTitle` model normalization / uniqueness | OPTIONAL | Partly covered by the request duplicates example |
| DJ5 | JobTitle rename keeps employees' stored names; `employee_counts` | OPTIONAL | Documented behaviour; low risk |
| DJ6 | `DepartmentPolicy` / `JobTitlePolicy` unit specs | OPTIONAL | DJ2 and the JobTitle request spec cover the outcomes |
| DJ7 | `User` → `JobTitle` validation | **ALREADY COVERED** | `user_job_title_spec` (5) |
| DJ8 | Employee form department select (keeps an inactive current department) | OPTIONAL | Employee-profile UI; not changed by the pilot |
| DJ9 | Performance consumers (snapshot, consistency, analytics) | ALREADY COVERED / out of scope | Performance is excluded; its specs are in the baseline set |

### 9. Locked decisions (additional, before M1)

| ID | Decision |
|---|---|
| **D-WF3** | **No Workforce boundary object (M2/M3) for this pilot.** No other domain calls `Department` / `JobTitle` through code (§3). The only cross-domain touch points are the shared `User` / `Business` models (D-WF1 stewardship, inverse associations), the sidebar shell and the admin gate. Creating `Workforce::` interfaces now would be a wrapper without a caller (`migration-pattern.md` §5 rules A, B, H). `app/services/workforce/` stays uncreated until a real cross-domain caller exists |
| **D-WF4** | **No M5 (operation services).** The controllers are simple policy-gated CRUD; the business rules (normalization, uniqueness, restrict-on-destroy) already live in the models; there is no duplicated rule |
| **D-WF5** | **Expected pilot steps:** M0 (done) → M1 (DJ1–DJ3) → M6 (Workforce boundary spec for Department/JobTitle with a reasoned allow-list: `User` / D-WF1, `Business` inverse, sidebar, admin gate, Organization & Access-shared employee-profile files) → optional M7 (collapsed `app/models/workforce/`, D-WF2) → M8 docs. No M8 database verification (no migration instantiates the models; no stored class names) |
| **D-WF6** | **Out of scope, recorded:** TD-WF1 (legacy `users.department` string shadowed by the association; `by_department` unused); `Business has_many` inverses stay; the `Admin::BaseController` gate stays; TD-PERF1, TD-ST1 |

### 10. M1 prerequisites

* Baseline file committed (`department-job-title-baseline-failures.txt`), with failures compared **by ID**; TD-PERF1
  IDs are treated as known-flaky (rerun).
* DJ1, DJ2 and DJ3 written against **unchanged** code, green, with no production change.
* Decisions D-WF1 to D-WF6 accepted.

### 11. Stop conditions encountered

* **One:** an unexpected failure (`reviews_analytics_spec.rb:38`) in the first baseline run. Work stopped and the
  failure was investigated without a fix. It was reported and classified by review as a pre-existing flaky failure
  (TD-PERF1, Option A).
* After recording, two full re-runs showed **no new failures** and the flaky example did not recur.
* **Not encountered:**
  * security behaviour changes
  * circular dependencies
  * ambiguous ownership
  * a need for the User/Employee redesign
  * a need for a database migration
  * a need for API or web changes
  * a need to modify another domain

### 12. M0 status

**M0 is complete.** M1 has not started. No production code, tests, schema or migrations were changed.

---

## Department + JobTitle — M6 Boundary Enforcement Status

**Status:** COMPLETE (uncommitted; awaiting review). This is enforcement only: no production change, and D-WF3 is
preserved.

### What the enforcement protects

`spec/architecture/workforce_catalog_boundary_spec.rb` follows the same style as
`permission_role_boundary_spec.rb`:

* It scans `app/**` and `lib/**` (`.rb`, `.erb`, `.rake`), ignoring full-line Ruby comments and ERB comments.
* It fails on any **new** reference to Workforce catalogue internals outside the allow-list:
  * the `Department` and `JobTitle` constants and class methods (`DepartmentPolicy` / `JobTitlePolicy` excluded)
  * the `departments` and `job_titles` collections and tables
* Employee attributes on `users` (`user.department`, `department_id`, `includes(:department)`, `users.job_title`) are
  **not** guarded, because any domain may read them (M0 §3, Decision Review Q3). Route helpers are not matched.
* A second example fails if an allow-listed file no longer needs its entry, so the list can only shrink.
* A third example pins what the token rule matches and what it leaves alone.
* **Verified:** a temporary probe in `app/services/` reading `business.departments` made the spec fail with its file
  and line. The probe was removed.

### Allow-list (repository evidence at `cafb6f6`; 24 files currently reference the catalogue)

**Workforce-owned** (`module-boundaries.md` §5), with direct use allowed:

| Path | Reason |
|---|---|
| `app/models/department.rb`, `app/models/job_title.rb` | The models themselves |
| `app/controllers/admin/departments_controller.rb`, `app/controllers/admin/job_titles_controller.rb` | Catalogue administration |
| `app/views/admin/departments/`, `app/views/admin/job_titles/` (dirs) | Catalogue administration screens |
| `app/controllers/admin/evaluation_templates_controller.rb`, `app/views/admin/evaluation_templates/` (dir) | Workforce Performance: templates are per department |
| `app/controllers/performance/`, `app/services/performance/` (dirs) | Workforce Performance: review filters, analytics name lookups, export column headers |
| `app/views/shared/_job_title_select.html.erb` | Workforce job-title dropdown (`JobTitle.options_for`) used by the employee form and onboarding |

**Cross-domain exceptions** (documented; each must keep its reason):

| Path | Reason |
|---|---|
| `app/models/user.rb` | **D-WF1:** `User#job_title_from_catalog` → `JobTitle.selectable?` (Workforce rule on the shared `users` table) |
| `app/models/business.rb` | **D-WF6:** `Business has_many :departments / :job_titles` (inverse associations) |
| `app/views/admin/users/_form.html.erb` | Employee-profile part of `admin/users` (department select). Workforce-owned per §5, but physically in an Organization & Access-shared file |
| `app/views/layouts/_sidebar.html.erb` | UI shell: catalogue nav entries and `policy(JobTitle).index?` |

No reference was **unclear**; none needed a stop.

### D-WF3 preserved

* **No Workforce boundary object was created.** There is no `app/services/workforce/`, no `Workforce::`, and no
  wrapper, alias, facade or service.
* `Department`, `JobTitle`, `User`, `Business`, Performance, onboarding, controllers, policies, routes, APIs, the
  database, migrations and schema are unchanged.

### Tests and baseline

* **New architecture spec:** 3 examples, 0 failures (plus the probe proof above).
* **Department + JobTitle characterization:** 31 examples, 0 failures.
* **Baseline set** (including `spec/architecture`) **plus characterization:** 353 examples, 2 failures.
  * `sidebar_active_state_spec.rb:215` and `:293`, both in `department-job-title-baseline-failures.txt`.
  * **No new failures.**
  * No baseline failure was fixed.
  * TD-PERF1 did not recur and is untouched.
* RuboCop: no offenses. `git diff --check`: clean.

**Next per D-WF5:** optional M7 (collapsed `app/models/workforce/`), then M8 docs. Neither has started.
