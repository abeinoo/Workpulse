# Next Migration Pilot — Candidate Analysis

**Status:** History of the pilot selections, plus the pilot status records.

* **Pilot 2, Workforce Department + JobTitle:** COMPLETE and pushed (`cafb6f6`, `b872d7a`, `0aa0066`).
* **Pilot 3, Workforce Performance:** COMPLETE and pushed (`8c1e2df`, `309fcc4`, `d7e83ca`, `ae74dcc`). It is on
  `origin/feature/api-foundation` at `ae74dcc`.
* **Pilot 4 (Milestone 1 numbering):** not selected — Milestone 1 ended after Pilot 3. Milestone 2 numbers its own
  pilots from 1 (see "Milestone 2 — Attendance & Payroll" below); its Pilot 4 is Penalty Rules (§19).

§1–§11 below are the original candidate analysis (at `c1aac8b`), kept as history.

**Original analysis baseline:** `feature/api-foundation` @ `c1aac8b`.
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

**At the time of this analysis, no pilot had been selected.** This section classified candidates only. Department +
JobTitle was selected afterwards (see "Selected pilot and locked decisions").

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

**Status:** COMPLETE (commit `b872d7a`, pushed). This is enforcement only: no production change, and D-WF3 is
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

---

## Department + JobTitle — M7 Physical Organization Status

**Status:** COMPLETE (commit `0aa0066`, pushed). This is a physical move only (D-WF2, D-WF4, D-WF5); D-WF3 is
preserved.

* **Moved (`git mv`, byte-identical; git records 0-line renames):**
  * `app/models/department.rb` → `app/models/workforce/department.rb`
  * `app/models/job_title.rb` → `app/models/workforce/job_title.rb`
* **Autoloading:** a new one-line initializer, `config/initializers/workforce_autoload.rb`:
  `Rails.autoloaders.main.collapse(Rails.root.join("app/models/workforce"))`. It is the same collapsed-folder
  approach as `organization_access_autoload.rb`. The classes stay **top-level `Department` / `JobTitle`** on
  `departments` / `job_titles`. No `Workforce` constant is defined; there is no `Workforce::Department` or
  `Workforce::JobTitle`.
* **Verified:**
  * `bin/rails zeitwerk:check` passes.
  * **Eager load** (`CI=1`): both resolve from `app/models/workforce/`, and the `User belongs_to :department` and
    `Business has_many :departments / :job_titles` associations resolve the identical classes.
  * **Development (lazy) load:** queries work, the source paths are correct, and there is no `Workforce` constant.
* **Specs:**
  * New `spec/architecture/workforce_model_location_spec.rb` (7 examples): top-level constant loaded from
    `app/models/workforce/`; tables unchanged; not namespaced under `Workforce`; same class behind the associations.
  * `spec/architecture/workforce_catalog_boundary_spec.rb`: only the two allow-list keys were updated to the new
    model paths. Its stale-entry check required this; the rule itself is unchanged.
* **Unchanged:** associations, validations, callbacks, controllers, policies, views, routes, APIs, factories, the
  database, schema and migrations. No compatibility alias was needed (constants unchanged).
* **Tests:**
  * Location spec: 7/7, including in random order.
  * `spec/architecture`: 17/17.
  * Characterization: 31/31.
  * **Baseline set:** 329 examples (322 + 7) with 2 failures, `sidebar_active_state_spec.rb:215` and `:293`, both
    baseline. **No new failures.** TD-PERF1 did not recur and is untouched.
* **No stop condition was encountered:**
  * no autoloading ambiguity
  * no namespace, database, association or migration change
  * no alias
  * no unexpected dependency
* **Next:** M8 (documentation close-out) has not started.

---

## Department + JobTitle — M8 Final Verification

**Status:** M8 COMPLETE (commit `0aa0066`, pushed). Pilot 3 was selected afterwards (see "Pilot 3 — Selection
and Fast-Track Plan").

### 1. Completed steps

| Step | Result | Commit |
|---|---|---|
| Candidate analysis, decision review, selection (D-WF1, D-WF2) | Department + JobTitle selected | `cafb6f6` |
| M0 — inventory, ownership, database analysis, baseline (D-WF3–D-WF6, TD-PERF1, TD-WF1) | Complete | `cafb6f6` |
| M1 — characterization (DJ1–DJ3 + consumers, 31 examples) | Complete | `cafb6f6` |
| M2/M3/M4/M5 | **Not applicable** (D-WF3: no cross-domain code callers; D-WF4: no operation services needed) | — |
| M6 — boundary enforcement (`workforce_catalog_boundary_spec.rb`) | Complete | `b872d7a` |
| M7 — physical organization (`app/models/workforce/`, collapsed) | Complete | uncommitted (with this M8 documentation) |
| M8 — final verification + documentation | Complete | uncommitted |

### 2. Final locations and constants

| Item | Final state |
|---|---|
| `Department` | `app/models/workforce/department.rb`, top-level `Department`, table `departments` |
| `JobTitle` | `app/models/workforce/job_title.rb`, top-level `JobTitle`, table `job_titles` |
| Autoloading | `config/initializers/workforce_autoload.rb` (collapse `app/models/workforce`) |
| `Workforce::` namespace | **Does not exist** (no constant, no `app/services/workforce/`) |
| Controllers, policies, views, routes | Unchanged locations (`admin/departments`, `admin/job_titles`, `DepartmentPolicy`, `JobTitlePolicy`) |
| Enforcement | `spec/architecture/workforce_catalog_boundary_spec.rb` (allow-list with reasons) and `spec/architecture/workforce_model_location_spec.rb` |

### 3. Test results (at M7 working tree)

| Suite | Result |
|---|---|
| `bin/rails zeitwerk:check` | All is good |
| Workforce architecture specs (boundary 3 + location 7) | 10 examples, 0 failures |
| All `spec/architecture` (PermissionRole + Workforce) | 17 examples, 0 failures |
| Department + JobTitle characterization | 31 examples, 0 failures |
| Baseline set + all characterization (Organization & Access and Workforce) + `spec/requests/security` (OA-S1–S8) | 601 examples, **2 failures** |

### 4. Known pre-existing failures (compared by exact ID)

* `spec/requests/sidebar_active_state_spec.rb:215` and `:293`. These are deterministic, in both baseline files, and
  **not new**.
* **TD-PERF1** (`performance/reviews_analytics_spec.rb:29/38/91`, flaky): did not recur in any M1–M8 run; untouched.
* **No new failures** in any step from M0 to M8.

### 5. Database, API, security and architecture status

* **Database:** no migration required or created; `db/schema.rb` unchanged; no table, column, index or foreign-key
  change. No migration instantiates the models, and no stored class names exist.
* **API / routes:** unchanged. No API references these models; `config/routes.rb` is untouched.
* **Namespace:** no change (`Department` / `JobTitle` stay top-level). **No compatibility alias exists.**
* **Cross-domain:** no new cross-domain dependency was introduced. The documented exceptions (D-WF1 `User`
  validation, D-WF6 `Business` inverses, the employee-profile part of `admin/users`, the sidebar) are unchanged and
  enforced.
* **Security:**
  * Authorization is unchanged: `manage_evaluation_templates` / `manage_settings` for departments,
    `manage_employees` / `manage_settings` for job titles.
  * Business isolation is unchanged (policy scopes; 404 for foreign records), as characterized.
  * The OA-S1–S8 security specs are green.

### 6. Six-domain verification

| Domain | Effect of this pilot |
|---|---|
| Organization & Access | Unchanged. `User` / `Business` keep their associations and the D-WF1 validation; the admin gate and sidebar are unchanged |
| **Workforce** | Owns `Department` and `JobTitle`, now physically under `app/models/workforce/` and enforced by an architecture spec |
| Attendance & Payroll | No references; unaffected |
| Inventory & Purchasing | No references; unaffected |
| Finance & Sales | No references; unaffected |
| Reporting | No references (Performance analytics is Workforce); unaffected |

### 7. What the pilot proved

* **Model ownership:** catalogue ownership can be established and enforced without moving behaviour or adding
  interfaces when there are no cross-domain code callers.
* **Physical organization:** collapsed `app/models/<domain>/` folders keep top-level constants for a second domain,
  with one initializer per domain (`organization_access_autoload.rb`, `workforce_autoload.rb`) and no alias.
* **Boundary enforcement:** the allow-list architecture spec generalizes. Domain-owned code living in shared files
  (the employee part of `admin/users`) is handled as a documented exception rather than a move.
* **Characterization strategy:** pinning only the touched contracts (31 examples) was enough; existing coverage was
  reused rather than duplicated.
* **Cross-domain exceptions:** a stewardship rule on a shared table (D-WF1) can stay in place as a reasoned,
  enforced exception.
* **Database compatibility:** moving the files needed no database work, because the constants and tables are
  unchanged and no migration references the models.
* **Rollback:** each step is a single `git revert` (M0/M1 `cafb6f6`, M6 `b872d7a`, M7 one commit).
* **Baseline discipline:** comparing by ID, plus a flaky marker in the baseline file (TD-PERF1), caught an unexpected
  failure, stopped the work, and classified it without hiding anything.

### 8. Intentionally unchanged

* `User`, Employee and `Business` (including D-WF1, the inverse associations, and the legacy `users.department`
  column, TD-WF1).
* Controllers, policies, views, routes and the admin gate.
* Performance and onboarding behaviour.
* Existing sub-area namespaces (`Shifts::`, `Scheduling::`, `Performance::`, `EmployeeDataRequests::`, `Requests::`,
  `Employee::`).

### 9. Not to be generalized automatically

* **Skipping M2–M5** is valid only when the M0 inventory proves there are no cross-domain **code** callers and no
  controller business logic. Components with real consumers (e.g. a future EmployeeDataRequest or BiometricDevice
  pilot) will need boundaries and/or services.
* **Treating domain-owned code in shared files as an exception** fits small surfaces. A large shared controller
  should eventually be split, in its own step.
* **A collapsed model folder** suits models referenced by migrations, associations or stored names. It is not a
  reason to move every model.

### 10. Locked decisions (now final for this pilot)

* **D-WF1:** `User` → `JobTitle` validation stays in `User`.
* **D-WF2:** Workforce structure convention.
* **D-WF3:** no Workforce boundary object.
* **D-WF4:** no operation services; models stay top-level.
* **D-WF5:** the pilot step set.
* **D-WF6:** the recorded out-of-scope items.

### 11. Technical debt discovered or confirmed (not fixed)

| ID | Item |
|---|---|
| TD-PERF1 | Flaky name assertions in `performance/reviews_analytics_spec.rb` (an HTML-escaped apostrophe in Faker names) |
| TD-WF1 | Legacy `users.department` string shadowed by the `department` association; `scope :by_department` has no callers |
| TD-ST1 | `ShiftTemplateEntry.branch` optional vs `ShiftAssignment.branch` required; template apply produces row errors; 12 baseline failures |
| MIG-1, MIG-2 | Pre-existing migration-history defects (from the PermissionRole pilot) |
| (observation) | `JobTitle.selectable?` does not trim whitespace, so a padded value never matches. Characterized; not changed |

### 12. Conclusion

**The Department + JobTitle pilot is complete:**

* The first Workforce component is physically owned by Workforce (`app/models/workforce/`).
* The boundary is enforced by architecture specs.
* Characterization is in place, and behaviour, database, API and security are unchanged.
* There is no new failure versus the baseline; the only failures remain the two pre-existing sidebar failures.
* It confirms the standard migration pattern for a component with no cross-domain code callers: M0 → M1 → M6 →
  (optional) M7 → M8.
* The next pilot (Pilot 3, Performance) was selected after review of this document.

---

## Pilot 3 — Selection and Fast-Track Plan

**Status:** Plan written at `0aa0066`; **implemented and complete** (see "Pilot 3 — Performance Migration Status").
It uses the fast track (`migration-pattern.md` §4, "Fast track").

### 1. Recommended candidate

**Workforce — Performance evaluation group.** It completes the Workforce Performance sub-area, builds directly on
Pilot 2 (Department), and is migrated as one coherent group.

### 2. Why (repository evidence)

* **Ownership is unambiguous:** `module-boundaries.md` §5 lists Performance under Workforce.
* **Large and coherent:** 57 own files (5 models, 5 `performance/` controllers + `admin/evaluation_templates`,
  4 policies, `Performance::` services and exports, views).
* **Zero cross-domain code callers by constant.** The 3 external hits are not real: a CSV sample string in
  `bulk_adjustments_controller.rb`, and `Employee::PerformanceScorer`, which is a different thing (below).
* **No database risk:** 0 data migrations call its constants; no stored class names (`audit_logs`, Active Storage:
  none).
* It depends only on Workforce (`Department`, already migrated) and Organization & Access (`User`, `Business`), so it
  is upstream-safe.

### 3. Scope (all Workforce)

* **Models:** `PerformanceReview`, `PerformanceReviewScore`, `PerformanceObservation`, `EvaluationTemplate`,
  `EvaluationCriterion`.
* **Controllers:** `Performance::{Base,Dashboard,Observations,Reports,Reviews}Controller`,
  `Admin::EvaluationTemplatesController`.
* **Services:** `Performance::{Analytics,ReviewAnalytics,ReviewComposer}`,
  `Performance::Exports::{EmployeeSummaryWorkbook,ReviewsWorkbook,PdfRenderer}`.
* **Policies:** `PerformanceReviewPolicy`, `PerformanceObservationPolicy`, `EvaluationTemplatePolicy`,
  `EvaluationCriterionPolicy`.
* **Tables:** `performance_reviews`, `performance_review_scores`, `performance_observations`,
  `evaluation_templates`, `evaluation_criteria`.

### 4. Not included

| Component | Reason |
|---|---|
| `Employee::PerformanceScorer` | Despite its name, it scores **attendance** (`AttendanceRecord`). It is called by `Payroll::RecommendationEngine` and `OperationsDashboardController`. Its ownership (Workforce namespace vs Attendance & Payroll data) is a separate question, recorded as **Q-P3-1** |
| `User` / `Business` / Employee | Inverse associations stay (same treatment as D-WF6); no User/Employee change |
| `Department` / `JobTitle` | Done in Pilot 2 |
| Controllers' and services' physical folders | Already in `performance/` namespaces; moving them adds no ownership value (D-WF2: `app/services/workforce/` is for public boundaries only) |
| TD-PERF1 | Flaky spec; recorded, not fixed |

### 5. Fast M0 dependency summary

| Kind | Finding |
|---|---|
| Internal (Workforce) | `Department has_many :evaluation_templates / :performance_reviews` (restrict); `PerformanceReview` snapshots `employee.department_id`; observation ↔ criterion department consistency; `EvaluationCriterion has_one :department, through: :evaluation_template` |
| Cross-domain | `User has_many :performance_reviews / :performance_observations` (`dependent: :destroy`) and `Business has_many` ×3 (Organization & Access → Workforce inverses); `admin/users_controller` + `admin/users/show` performance tab (employee-profile part, Workforce per §5); `workspace_helper` nav (UI shell); `user.scope_for(:view_monthly_reviews / :view_notes / :create_observations)` and `filter_by_data_scope` (allowed Organization & Access interfaces) |
| Direct writes across boundaries | **None** |
| Circular dependencies | **None** (Workforce → Organization & Access only) |
| Security-sensitive paths | Human-resources evaluation data. `PerformanceReviewPolicy::Scope`: managers by data scope, employees see their own **finalized** reviews. `finalize?` (`finalize_reviews`); `update?` blocked once finalized. Observation edit/destroy only by the observer or the owner. Data-scope filtering per the permission scope |

### 6. Characterization coverage

* **Exists (57 examples):**
  * `performance_review_spec` (4: snapshot)
  * `reviews_analytics_spec` (9, TD-PERF1 flaky)
  * `reviews_index_spec` (3)
  * `performance/review_analytics_spec` (25)
  * `attendance_performance_workspace_navigation_spec` (16)
  * observation consistency (Pilot 2 `department_spec`)
* **Missing (to add in M1; security-relevant first):**
  1. Review lifecycle: create (draft) → submit → finalize; no edit after finalize; `ReviewComposer` scoring.
  2. Review visibility: manager data scope (branch/business), employee sees own finalized only, cross-business 404.
  3. Observations: create, scope by `view_notes` / `create_observations`, edit/destroy only by observer or owner,
     cross-business isolation.
  4. Evaluation templates admin: CRUD + criteria, authorization (`manage_evaluation_templates` / `manage_settings`),
     business isolation.
* **Not needed:** analytics and exports (already covered); navigation (covered).

### 7. Boundary strategy

* Everything in §3 becomes **Workforce-owned and enforced**: extend the existing
  `workforce_catalog_boundary_spec.rb` approach to the Performance constants and tables.
* **Allowed cross-domain access:** the `User` / `Business` inverse associations (documented exceptions), the
  employee-profile performance tab, UI-shell navigation, and Organization & Access authorization interfaces.
* **No boundary/interface object:** no other domain calls Performance through code (the D-WF3 rationale applies).

### 8. Fast-track sequence

| Fast-track step | Standard IDs | Pilot 3 content | Optional? |
|---|---|---|---|
| M0 Fast inventory | M0 | This section, plus a baseline capture of the Performance set | — |
| M1 Characterization | M1 | Gaps 1–4 above | Required |
| M2 Boundary | M6 (enforcement) | Extend the Workforce boundary spec to Performance | Required |
| M3–M5 Migration | M2–M5 | **None needed** (no cross-domain callers; rules already in models/policies) | Skipped (evidence) |
| M6 Physical organization | M7 | `git mv` the 5 models into `app/models/workforce/` (existing collapse) + location spec | Optional |
| M7 Verification + M8 Docs | M8 | Focused + architecture + security specs, Zeitwerk, ID comparison; one status section | Required |

**Combinable:** M2 enforcement + M6 physical move + verification in **one commit** after M1 is committed (the
allow-list paths and the move must change together anyway). So the plan is 2 implementation commits: M1, then
M2 + M6 + M8.

### 9. Risk assessment

| Area | Risk | Note |
|---|---|---|
| Security | Medium | Human-resources data visibility. Mitigated by characterizing scopes **before** any move; the move itself changes no code |
| Data integrity | Low | No schema change; no data migration; finalized reviews immutable by policy (characterized) |
| Regression | Low | Byte-identical moves; constants unchanged |
| Coupling | Low | Only documented inverses and UI shell |
| Migration | Low | Same mechanics as Pilot 2; one caveat: TD-PERF1 lives in this spec area (flaky IDs already recorded) |

### 10. Verification plan

* M1 Performance characterization specs (new).
* Existing Performance specs (57).
* Pilot 2 characterization (31).
* `spec/architecture` (boundary + location).
* `spec/requests/security` (OA-S1–S8).
* The established baseline set.
* `bin/rails zeitwerk:check`.
* Compare failures **by ID** against `department-job-title-baseline-failures.txt`: only `sidebar_active_state:215/293`
  expected; TD-PERF1 IDs are known-flaky.

### 11. Files likely to change (not modified yet)

* `spec/characterization/workforce/performance_*_spec.rb` (new, M1).
* `spec/architecture/workforce_catalog_boundary_spec.rb` (tokens + allow-list) and
  `spec/architecture/workforce_model_location_spec.rb` (5 more models).
* `app/models/{performance_review,performance_review_score,performance_observation,evaluation_template,evaluation_criterion}.rb`
  → `app/models/workforce/` (`git mv`, byte-identical; no new initializer).
* This document (one status section).

### 12. Stop conditions

* A new failing ID.
* The review or observation visibility behaviour cannot be characterized stably, or differs from the documented
  policy.
* A real cross-domain code caller appears (it would need an interface decision).
* Any schema or migration need.
* Any namespace change or alias need.
* Q-P3-1 (`PerformanceScorer`) turns out to be entangled with the group.

### 13. Next implementation checkpoint (after approval)

1. Capture the Performance baseline (existing 57 examples + Pilot 2 set), compared by ID.
2. Write M1 gaps 1–4 against unchanged code (no production change), run them in default and random order, and
   report. Stop for review before M2/M6.

**Open question:** **Q-P3-1:** ownership of `Employee::PerformanceScorer` (attendance-based score in a Workforce
namespace, consumed by Attendance & Payroll and the operations dashboard). Not part of Pilot 3.

---

## Pilot 3 — Performance Migration Status (complete)

**Status:** COMPLETE and pushed to `origin/feature/api-foundation` (final commit `ae74dcc`). It used the fast
track, mapped to standard steps M0, M1,
M6, M7 and M8.

| Step | Result | Commit |
|---|---|---|
| M0 fast inventory + baseline | Focused set 499 examples; only `sidebar_active_state:215/293` failing | — |
| **SEC-P3-1** (found in M0, fixed separately) | Same-business validations on `EvaluationTemplate` (department), `PerformanceReview` (employee / department / reviewer), `PerformanceReviewScore` (criterion template), `PerformanceObservation` (employee / observer / criterion template); request security spec (11); `performance_review` factory defaults to same-business | `8c1e2df` |
| **PERF-D1** (found in M1, fixed separately) | An invalid review period re-rendered the form with `Date::Error`; `ReviewComposer#month_observations` now returns none for an invalid period; regression spec (2) | `309fcc4` |
| M1 characterization | 33 examples: reviews lifecycle + visibility (12), observations (9), template admin (12) | `d7e83ca` |
| M3–M5 | **Skipped** on M0 evidence: no cross-domain code callers; business rules already in models and policies | — |
| M6 boundary + M7 physical + M8 | See below | `ae74dcc` |

**Physical move.** `git mv`, byte-identical, into the **existing** collapsed `app/models/workforce/`. No new
initializer. Constants and tables are unchanged:

* `app/models/performance_review.rb` → `app/models/workforce/performance_review.rb`
* `app/models/performance_review_score.rb` → `app/models/workforce/performance_review_score.rb`
* `app/models/performance_observation.rb` → `app/models/workforce/performance_observation.rb`
* `app/models/evaluation_template.rb` → `app/models/workforce/evaluation_template.rb`
* `app/models/evaluation_criterion.rb` → `app/models/workforce/evaluation_criterion.rb`

**Boundary.** `workforce_catalog_boundary_spec.rb` now also guards the Performance constants and their
collections/tables. **No boundary or interface object was needed.**

* **Workforce-owned:** the 5 models, `app/views/performance/` (added), `app/controllers/performance/`,
  `app/services/performance/`, and admin evaluation templates.
* **Documented exceptions:**
  * `User` / `Business` inverse associations
  * the employee-profile performance tab (`admin/users_controller`, `admin/users/show`)
  * `workspace_helper` (UI-shell navigation)

A probe confirmed the spec flags new access. The location spec now covers all 7 Workforce models.

**Verification:**

* Architecture: 32/32.
* Broad set (all characterization, Performance, security including SEC-P3-1 and PERF-D1, architecture, employee
  and onboarding specs): 693 examples. The only failures are `sidebar_active_state_spec.rb:215` and `:293`
  (baseline), so there are **no new failures**.
* TD-PERF1 did not recur.
* `zeitwerk:check` passes; eager load resolves all 5 from `app/models/workforce/` with no `Workforce` constant.
* RuboCop clean; `git diff --check` clean.

**Known defects remaining (not fixed):**

* **PERF-D2:** deleting a template whose criteria are scored or observed is correctly blocked, but the admin gets an
  empty alert, because the restriction error sits on the nested criterion. Pinned in the characterization spec.
* TD-PERF1, TD-WF1, TD-ST1, MIG-1, MIG-2 (unchanged).
* **TD-FIN1** (found in the milestone review full-suite run at `ae74dcc`):
  `spec/requests/finance/bank_dispute_depositor_mismatch_spec.rb:128`.
  * **Status:** pre-existing relative to this milestone; **flaky**; it passed in 2 of 3 isolated reruns.
  * **Root cause:** the same as TD-PERF1. Faker can generate a name with an apostrophe (observed: `O'Connell`),
    which the rendered HTML escapes, so the spec's plain-text name expectation fails depending on the generated
    data.
  * **Not a regression:** the branch did not modify Finance code or specs.
  * **Not fixed;** recorded as `flaky` in `permission-role-baseline-failures.txt`.
* Q-P3-1 (`Employee::PerformanceScorer` ownership) remains open.

There are no database, schema, migration, route or API changes.

---

# Milestone 2 — Attendance & Payroll

**Status:** M0 audit, **security hardening** (§5.1, §17), **Pilot 1 (Biometric Device + PunchService)** and
**Pilot 2 (Employee Obligations)** are **COMPLETE**:

* Pilot 1: M1 `1024ffb` (§13), M6 `8eac847` (§14), M7 `bea07f8` (§15), M8 (§16).
* Pilot 2: §17.
* **Milestone 2 — Finance & Sales Expenses (Pilot 3):** **COMPLETE** (§18, close-out §18.8). Standard path: M1
  `98edd8e`, M2 `4b94668`, M3 `d009f0d`, M4 `0ca2dc5`, M5 not needed, M6 `ddaceb1`, M7 `ee47554`, M8 docs. Cycle
  F3 eliminated; FS-D3 recorded as open debt (§10).
* **Milestone 2 final gate (full suite vs `main`):** passed after review at `b28110f` (§18.9) and again with Pilot 4
  at `ce3ce00` (§19.13). **Milestone 2 (security hardening, Pilots 1–4) is READY FOR PR** from
  `feature/milestone-2-attendance-payroll` once Pilot 4 is fast-forwarded into it (PR not created, not merged).
* **Pilot 4 — Attendance & Payroll Penalty Rules:** **COMPLETE** on `feature/pilot-4-penalty-rules` (from
  `b28110f`; to be fast-forwarded into the milestone branch): M0 `b73fc34`, M1 `3efb46b`, M2 `40e5ed0`, M3 `4d7ae92`, M4 `a2ae7aa`, M5 not needed, M6
  `3fd9ba2`, M7 `a3b6463`, M8 docs (§19.12). The WF ↔ AP Shift / PenaltyRule write is inverted; P4-D1 open.

No schema, migration, route or API has changed. The only production behaviour changes are:

* the security fixes: §5.1, plus SEC-M2-10/-11 and the SEC-M2-4 follow-up in §17;
* the payroll-correctness fixes AP-D4 and AP-D5 (§17);
* SEC-M2-12 and the FS-D1 / FS-D2 correctness fixes (§18).

Each is in its own `fix:` commit; every M7 is a byte-identical file move. Milestone 1
sections above are historical and unchanged.

* **Branch:** `feature/milestone-2-attendance-payroll`, created from `origin/main` @ `c054fa3`.
* **Audit date:** 2026-10-06.
* **Baseline file:** `attendance-payroll-baseline-failures.txt`.
* **Source of truth:** `module-boundaries.md` §6 (Attendance & Payroll, "AP") and §12–§14. Discrepancies are in §3.3.

## 1. Executive summary

* **Inventory:** AP spans 19 models, 72 services, 29 controllers, 11 policies, 1 job and 1 rake file (§2).
* **Security first:** the audit found **six confirmed security defects** (§5; four High, two Medium) and two code-evident
  scope gaps. Three are admin controllers in AP with **no authorization call at all**. Following the Pilot 3
  precedent (SEC-P3-1), each must be fixed in its own approved commit before any pilot that touches it.
  **Update:** all High findings are now **fixed** (SEC-M2-1, -2, -3, -4), plus **SEC-M2-9**, which was found while
  fixing SEC-M2-3 (§5.1). The Medium/Low findings remain deferred (§5.2).
* **Coupling:** AP has real cross-domain callers in most groups: Workforce requests, the payroll → Finance expense,
  and readers in Reporting, Workforce and Inventory & Purchasing.
* **Selected Pilot 1 (approved):** **Biometric Device + PunchService**, the punch capture channel (§7). It is
  the only cohesive AP group with **zero cross-domain code callers** and **zero baseline failures**. It already has a
  characterized device API.
* **Precondition:** Pilot 1 was blocked until **SEC-M2-1** (device administration without a permission check) was
  fixed. That is **done** (`28b2100`), so Pilot 1 qualifies for the fast track (M0 → M1 → M6 → M7 → M8). It has
  **not started**.

## 2. Domain inventory (repository evidence at `c054fa3`)

Counted from the file list the dependency scan used: 131 AP files, 13,739 lines (models, services, controllers,
policies, job; views excluded).

### 2.1 Attendance

| Area | Code |
|---|---|
| Models | `AttendanceRecord` (96 lines), `AttendanceAdjustment` (12), `AttendanceImportLog` (28), `BiometricDevice` (26), `BiometricPunchLog` (36; logs **both** biometric punches and mobile rejections, `SOURCES = biometric mobile`), `PenaltyRule` (43) |
| Services `attendance/` (20) | `punch_service`, `check_in_service`, `check_out_service`, `manual_entry_service`, `bulk_manual_entry_service`, `adjustment_service`, `record_deleter`, `record_recomputer`, `time_calculator`, `penalty_calculator`, `punch_window`, `duration_check`, `geolocation_validator`, `timestamp_parser`, `anomaly_detector`, `daily_stats`, `csv_importer`, `manual_records_csv_parser`, `historical_backfill`, `status_backfill` |
| Reports | `Reports::AttendanceSummary` |
| Web controllers | `AttendanceController`, `AttendanceRecordsController` (362 lines), `Admin::AttendanceRecordsController` (a legacy duplicate path, §5), `Admin::AttendanceImportsController`, `Admin::BiometricDevicesController`, `Admin::BiometricPunchLogsController`, `Admin::PenaltyRulesController` |
| API | `Api::V1::AttendanceController` (mobile check-in/out/today), `Api::V1::PunchesController < BiometricBaseController` (device-token realm), `Api::V1::AttendanceRecordsController`, `Api::V1::PenaltyRulesController`, `Api::V1::Reports::AttendanceController` |
| Policies | `AttendanceRecordPolicy`, `AttendanceImportLogPolicy`, `PenaltyRulePolicy`. **No `BiometricDevicePolicy` / `BiometricPunchLogPolicy` exists** |
| Jobs / tasks | `lib/tasks/attendance.rake` (`Attendance::HistoricalBackfill`) |
| `users` columns (AP stewardship) | `allow_mobile_attendance`, `allow_biometric_attendance` |

### 2.2 Payroll

| Area | Code |
|---|---|
| Models | `PayrollPeriod` (70), `PayrollEntry` (195), `PayrollLineItem` (148), `PayrollAdjustment` (183), `PayrollAdjustmentEdit` (10), `PayrollAuditLog` (44), `PayrollSnapshot` (30), `PayrollPeriodBranchReview` (12), `SalaryProfile` (43), `Advance` (26), `EmployeeObligation` (368), `ObligationDeduction` (25), `ObligationPostponement` (26) |
| Services `payroll/` (38) | Lifecycle (`period_generator`, `auto_generator`, `regenerator`, `draft_regenerator`, `entry_calculator`, `entry_recalculator`, `submit_for_review`, `branch_review_completer`, `changes_requester`, `approver`, `reopener`, `snapshot_service`); corrections (`overtime_overrider`, `bulk_overtime_overrider`, `overtime_recalculator`, `deduction_waiver(_persistence)`, `bulk_deduction_waiver`, `addition_canceller`, `addition_cancellation_persistence`, `line_item_reviewer`, `entry_review_clearer`, `bulk_entry_review_clearer`); adjustments (`adjustment_applier`, `adjustment_approval`, `adjustment_editor`, `adjustment_remover`); deductions (`advance_deductor`, `obligation_deductor`, `obligation_editor`, `obligation_installment_postponer`); request effects (`permission_applier`, `punch_correction_applier`); insight (`anomaly_detector`, `recommendation_engine`, `insights_presenter`, `period_financial_summary`); **`insurance_expense_generator`** (writes Finance & Sales) |
| `salary/` (4) | `advance_eligibility_calculator`, `daily_rate_calculator`, `overtime_calculator`, `profile_updater` |
| `adjustments/` (5) | `bulk_create_service`, `bulk_csv_parser`, `bulk_review`, `selectable_periods`, `summary_data` |
| Reports | `Reports::PayrollSummary`, `PayrollCsvExporter`, `BankTransferCsvExporter` |
| Web controllers | `PayrollPeriodsController` (543 lines), `PayrollEntriesController`, `PayrollLineItemsController`, `PayrollAdjustmentsController`, `PayrollDashboardController`, `AdjustmentsController` (299), `BulkAdjustmentsController` (215), `Admin::SalaryProfilesController`, `Admin::EmployeeObligationsController` |
| API | `Api::V1::{PayrollPeriods,PayrollEntries,PayrollLineItems,PayrollAdjustments,SalaryProfiles,Advances}Controller`, `Api::V1::Reports::PayrollController` |
| Policies | `PayrollPeriodPolicy`, `PayrollEntryPolicy`, `PayrollLineItemPolicy`, `PayrollAdjustmentPolicy`, `PayrollDashboardPolicy`, `SalaryProfilePolicy`, `AdvancePolicy`, `EmployeeObligationPolicy` |
| Jobs | `Payroll::AutoGenerateJob` (`config/recurring.yml`) |
| Not in a web/API surface | `Advance` has no web controller; it is created only by `Requests::Approver#pay` (Workforce) |

### 2.3 Workforce code that touches AP

| Workforce code | AP touch |
|---|---|
| `Requests::Approver` | `approve_standard` → `Payroll::PermissionApplier`; `pay` → **`Advance.create!`** (`Requests::BulkPaymentService` routes through `pay`) |
| `Requests::PunchCorrectionApplier` | **`AttendanceRecord#save!`** + `Attendance::RecordRecomputer` + `Payroll::PunchCorrectionApplier` |
| `Requests::Canceller` | **`PayrollLineItem` destroy/update/create** (two paths) **and `AttendanceRecord#save!`** + `RecordRecomputer` |
| `Requests::PunchCorrectionAssessment` | reads `Attendance::PunchWindow`, `DurationCheck`, recomputes an unsaved copy |
| `EmployeeRequest` model | `has_one :advance`; `left_joins(:advance)` priority SQL; `within_advance_limit` → `Salary::AdvanceEligibilityCalculator` |
| `EmployeeRequestsController` + views | `AttendanceRecord` lookups, `Salary::AdvanceEligibilityCalculator`, `Attendance::DurationCheck` |
| `Employee::InsuranceProfileUpdater` | → `Payroll::EntryRecalculator.recalculate_all_open_periods_for` |
| `Admin::EmployeeInsuranceProfilesController` | reads `PayrollPeriod` |
| `Admin::UsersController#show` + view | **salary profile card** and **active obligations card** (§5 SEC-M2-5) |
| `ShiftAssignment#has_attendance_records?`, `ShiftAssignmentsController` (raw SQL `EXISTS … attendance_records`) | read attendance |
| `Shift has_many :penalty_rules` + `accepts_nested_attributes_for` (`Admin::ShiftsController` permits `penalty_rules_attributes`), `admin/shifts/_form` | **writes `penalty_rules`** |
| `Employee::PerformanceScorer` | Workforce namespace, scores `AttendanceRecord`; called by `Payroll::RecommendationEngine` and the operations dashboard (Q-P3-1) |

## 3. Ownership analysis

### 3.1 Groups

| Group | Current owner (by code location) | Intended owner | Tables | Main entry points | Major dependencies |
|---|---|---|---|---|---|
| **Punch capture channel** | AP | AP | `biometric_devices`, `biometric_punch_logs` | `admin/biometric_devices`, `admin/biometric_punch_logs`, `api/v1/punches` (device realm), mobile rejection log in `api/v1/attendance` | `Attendance::PunchService` → `AttendanceRecord`; `Shifts::AssignmentResolver` (WF read); `Business` inverse (OA) |
| **Attendance records & adjustments** | AP | AP | `attendance_records`, `attendance_adjustments`, `attendance_import_logs` | `attendance`, `attendance_records`, `admin/attendance_records`, `admin/attendance_imports`, API attendance/records/reports | WF requests write it; Reporting reads it heavily; drives payroll regeneration |
| **Penalty rules** | AP model, edited via WF `Shift` | AP | `penalty_rules` | `admin/shifts/:id/penalty_rules`, `api/v1/shifts/:id/penalty_rules`, shift form nested attributes | Attached to WF `Shift` by FK; consumed by `PenaltyCalculator` / `TimeCalculator` |
| **Salary configuration** | AP | AP | `salary_profiles` | `admin/users/:id/salary_profiles`, `api/v1/users/:id/salary_profiles` | Read by WF employee page; triggers `EntryRecalculator` |
| **Obligations** | AP | AP | `employee_obligations`, `obligation_deductions`, `obligation_postponements` | `admin/employee_obligations` | Read by WF employee page; consumed by `ObligationDeductor` in entry calculation |
| **Advances** | AP model, written by WF | AP | `advances` | `api/v1/advances` (read), `Requests::Approver#pay` (write) | WF ↔ AP cycle (§4.3) |
| **Payroll adjustments** | AP | AP | `payroll_adjustments`, `payroll_adjustment_edits` | `adjustments`, `bulk_adjustments`, `payroll_adjustments`, API | Applied as `PayrollLineItem`s (payroll core); `application_helper` reads a constant |
| **Payroll core** | AP | AP | `payroll_periods`, `payroll_entries`, `payroll_line_items`, `payroll_snapshots`, `payroll_audit_logs`, `payroll_period_branch_reviews` | `payroll_periods` (543-line controller), entries, line items, dashboard, API, `Payroll::AutoGenerateJob` | **Writes Finance & Sales** (insurance expense); read by Reporting, Finance reports and Laundry |

### 3.2 Workforce vs Attendance & Payroll boundary (confirmed by code)

| Concept | Owner | Evidence |
|---|---|---|
| Employee, `Department`, `JobTitle` | **WF** (M1, unchanged) | AP only reads `users` rows; no AP code reads department or job title |
| `Shift`, `ShiftRuleProfile`, `ShiftTemplate(Entry)` | **WF** | AP reads them through `ShiftAssignment` / `Shifts::AssignmentResolver` (20 AP files); none is written by AP |
| `ShiftAssignment`, scheduling, `BranchMembership` | **WF** | AP reads only `current`, `active_on`, `user_ids_for_branches`, `branch_ids_for_users`, `branch_names_by_user`, `branch_ids_by_user`; it never writes them |
| `EmployeeRequest` (workflow) | **WF** | Request lifecycle, approvals and self-approval live in `Requests::*`. Its *effects* (advances, attendance and line-item changes) are AP data |
| `PenaltyRule` | **AP** | Only consumed by penalty and time calculation. The shift form is a UI composition (`module-boundaries.md` §14.2 #9) |
| `Advance` | **AP** | Deducted and settled by payroll |
| `Employee::PerformanceScorer` | **Unclear (G)** | Workforce namespace, AP data (Q-P3-1, still open) |

Workforce-owned concepts stay in Workforce. Nothing in this milestone moves a shift, assignment, request,
department or job-title concept into AP.

### 3.3 Discrepancies vs `module-boundaries.md`

| # | Document says | Code shows |
|---|---|---|
| DS-1 | §12.2/§14.2 #1: `InsuranceExpenseGenerator` "writes `expenses`" | It writes `expenses`, **`expense_categories`** (`find_or_create_by!`) and **`expense_allocations`**, and calls `Finance::NumberSequencer` |
| DS-2 | §14.2 #4: `Requests::Canceller` restores `PayrollLineItem` | It **also writes `AttendanceRecord`** (punch-correction rollback, `save!` + recompute) |
| DS-3 | §14.2 #2: `pay` and `BulkPaymentService` stamp advances paid | `BulkPaymentService` calls `Requests::Approver.pay`; there is **one** `Advance.create!` site |
| DS-4 | §12.2 WF → AP lists requests, insurance, salary display and request validation | Undocumented upward reads also exist: `ShiftAssignment#has_attendance_records?`, `ShiftAssignmentsController` raw SQL on `attendance_records`, `Admin::EmployeeInsuranceProfilesController` → `PayrollPeriod`, and the **obligations card** on the employee page |
| DS-5 | §6 lists AP policies | There is no policy for biometric devices or punch logs, and three AP admin controllers call no `authorize` (§5) |
| DS-6 | §3.2: the attendance-channel flags are AP-stewarded | Confirmed (`PunchesController`, `Api::V1::AttendanceController`); still an open confirmation in §20.2 |
| DS-7 | — | Two different "branch members" paths inside AP: `EmployeeObligation.for_branch` uses `BranchMembership`, and `PayrollAdjustment.for_branch` uses `ShiftAssignment.current` directly |
| DS-8 | §6: `BiometricPunchLog` is device data | It is the punch log for **both** channels (`source: biometric | mobile`); the mobile API writes rejection rows |

## 4. Cross-domain dependency audit

**Counting rule:** a dependency is a distinct (source file → target domain) code edge. Comment-only matches are
excluded; for example, the `Advance` matches in `api/list_query.rb`, `purchase_request*` and
`recurring_expense_generator` are prose. Raw reference lines are given where useful.

### 4.1 Summary

| Class | Meaning | Count | Detail |
|---|---|---|---|
| **A** | Internal to AP | 11 regeneration call sites + the Attendance ↔ Payroll internal cycle | Attendance → `DraftRegenerator` / `EntryRecalculator` from 5 attendance services, 2 salary-profile controllers, `Salary::ProfileUpdater`, 2 obligation services, and `DraftRegenerator` itself |
| **B** | Read-only dependency | **36 file edges** | AP → WF reads: 24 files / 30 lines (allowed direction). Reporting → AP: 6 files. Inventory & Purchasing → AP: 1 (`Laundry::LaundryCostSummaryReport`). WF → AP reads (upward): 5 code files (`EmployeeRequestsController`, `EmployeeRequest`, `ShiftAssignment`, `ShiftAssignmentsController`, `Admin::EmployeeInsuranceProfilesController`) |
| **C** | Valid documented exception | **16** | OA inverse `has_many` ×11 (`User` 5, `Business` 4, `Branch` 2); WF `Shift has_many :penalty_rules` (association only); FS `Expense belongs_to :source_payroll_period`; UI shell (`_sidebar`, `workspace_helper`, `application_helper` `PayrollAdjustment::POSITIVE_TYPES`) |
| **D** | Cross-domain business operation | **4** | WF → AP service calls: `Requests::Approver` → `Payroll::PermissionApplier`; `Requests::PunchCorrectionApplier` → `Payroll::PunchCorrectionApplier`; `Requests::Canceller` → `Attendance::RecordRecomputer`; `Employee::InsuranceProfileUpdater` → `Payroll::EntryRecalculator` |
| **E** | Direct cross-domain write | **5 write paths, 7 tables** | WF → AP: (1) `Requests::Approver#pay` → `advances`; (2) `Requests::Canceller` → `payroll_line_items` + `attendance_records`; (3) `Requests::PunchCorrectionApplier` → `attendance_records`; (4) `Shift` nested attributes → `penalty_rules`. AP → FS: (5) `Payroll::InsuranceExpenseGenerator` → `expenses`, `expense_categories`, `expense_allocations` |
| **F** | Circular dependency (cross-domain) | **3** | (1) **WF ↔ AP requests/advances:** WF writes `advances` / line items / attendance; AP reads `EmployeeRequest.approved_minutes`, pending advance requests, `Advance belongs_to :employee_request`. (2) **WF ↔ AP shift assignment/attendance:** AP reads `ShiftAssignment` everywhere; WF reads `attendance_records` to decide editability. (3) **AP ↔ FS:** AP writes expenses; FS references `source_payroll_period` and reads `PayrollEntry` in its reports |
| **G** | Unclear ownership | **3** | `Employee::PerformanceScorer` (Q-P3-1); attendance-channel flags on `users` (§20.2); AP services under the generic `reports/` namespace plus the AP partial `shared/_adjustment_already_paid_section` |

**Totals:**

* **Cross-domain dependencies (B–E, F and G excluded):** 61 (36 + 16 + 4 + 5).
* **Requiring future work (D + E):** 9.
* **Circular:** 3 cross-domain, plus 1 internal (Attendance ↔ Payroll, already documented in `module-boundaries.md` §13).
* **Direct cross-domain writes:** 5.

Reproduce: the AP file list and grep patterns used are recorded in §9.

### 4.2 Pairs requested for special attention

| Edge | Finding |
|---|---|
| Workforce → AP | Reads (5 files), 4 business operations (D), 4 direct writes (E #1–#4). The main cluster is `Requests::*` |
| AP → Workforce | 24 files / 30 lines, all reads (assignments, resolver, approved request minutes, performance scorer); **no AP writes into WF or OA tables** (verified by write-pattern scan) |
| AP → Finance & Sales | 1 service, 3 FS tables, inside `Payroll::Approver#finalize` (E #5) |
| Employee Requests → AP | E #1–#3 and D #1–#3 |
| Attendance → Payroll | Internal (A): 11 recalculation call sites; attendance changes refresh open payroll entries |
| Payroll → Finance | E #5 only. No salary-payment or advance-disbursement Finance record exists |
| Payroll → Workforce | Reads only: `ShiftAssignment` branch attribution (5 files), `EmployeeRequest.approved_minutes`, `Employee::PerformanceScorer` |

## 5. Security audit

**Status:** SEC-M2-1, -2, -3, -4 and -9 are **fixed** (§5.1). SEC-M2-5, -6, -7 and -8 and AP-D1 are **deferred**
(§5.2). The table below is the original M0 record, kept unchanged as evidence; SEC-M2-9 was added when it was found.

These findings **block** any pilot that touches the affected path. Following the SEC-P3-1 precedent, each is
fixed in its own approved commit before characterization (`migration-pattern.md` §4, Pilot 3 lessons).

Each was proven with a throwaway request probe that is **not** in the repository, run on the transactional test
database. The probe actor holds only `view_employees` unless stated otherwise.

| ID | Severity | Path | Defect | Proof |
|---|---|---|---|---|
| **SEC-M2-1** | **High** | `Admin::BiometricDevicesController` (all actions) | **No `authorize` call, and no policy exists.** The gate is `Admin::BaseController#require_admin_access!`, which accepts any of 13 permissions (including `view_employees`, `view_attendance` and `view_payroll`; the default branch-manager and area-manager roles hold all three). Such a user can **read a device token, regenerate it, and create or destroy devices**. A token authenticates `POST /api/v1/attendance/punch` for **any active employee of the business** (24-hour window). That is attendance falsification, and through it payroll. The intended permission is `manage_devices` (the sidebar gate) | Token shown (200), regenerated (changed), device created |
| **SEC-M2-2** | **High** | `Admin::AttendanceRecordsController#update` (`PATCH /admin/attendance_records/:id`) | **No `authorize`**, and the lookup is business-wide with no data scope. Any admin-gate holder can rewrite check-in/check-out of any employee **including their own** (`Attendance::AdjustmentService`, which checks no permission) and so change pay. The policy-based path (`AttendanceRecordsController`, `manage_attendance`) is bypassed | Another employee's record changed; the actor's **own** record changed |
| **SEC-M2-3** | **High** | `Admin::PenaltyRulesController` (new/create/edit/update/destroy) | **No `authorize`.** `PenaltyRulePolicy` requires `manage_shifts`, but it is never called. Any admin-gate holder can create, edit or delete penalty rules on any shift in the business, changing payroll deductions | Rule created (0 → 1) |
| **SEC-M2-4** | **High** (cross-business) | `Admin::EmployeeObligationsController#create` | `user_id` comes from params with **no business check** (and `EmployeeObligation` has no same-business validation), and no `manage_obligations` data-scope check. An obligation can be created in business A for a user of **business B**. `Payroll::ObligationDeductor` selects obligations by user only (`for_user`), so **business B's payroll would deduct it** | Created; `obligation.business` = A, `user.business` = B. Deduction effect is code-evident (`obligation_deductor.rb:27-31`) |
| **SEC-M2-5** | Medium | `admin/users#show` (salary card, active obligations card) | The page is authorized by `UserPolicy#show?` (`view_employees` + employee scope) only. It renders **base salary, salary type, overtime multiplier and salary history** without `SalaryProfilePolicy#show?` (`manage_salary_profiles` / `view_payroll` / own), and obligations without `manage_obligations`. Default roles pair `view_employees` with `view_payroll`, so this is exposed through custom roles | Salary visible with `view_employees` (business scope) and **no** `view_payroll` |
| **SEC-M2-6** | Medium | `Admin::SalaryProfilesController#create/update` | The employee is looked up business-wide (`current_user.business.users.find`), and the policy ignores the `manage_salary_profiles` scope (a scopable permission). A holder scoped to **self** created profiles for **themselves**, another employee and the **owner**. Self-salary changes have no segregation-of-duties guard | 3/3 created |
| SEC-M2-7 | Medium (code-evident, not probed) | `AdvancePolicy::Scope`, `SalaryProfilePolicy::Scope` | Any `view_payroll` holder gets **business-wide** advances and salary profiles. The configured `view_payroll` scope is ignored, unlike `PayrollEntryPolicy` / `PayrollLineItemPolicy`, which honour it. Exposed via `GET /api/v1/advances` | Code reading |
| **SEC-M2-9** | **High** (found while fixing SEC-M2-3, not in the M0 scan) | `Admin::ShiftsController` (all actions) | **No `authorize`** although `ShiftPolicy` requires `manage_shifts` for create/update/destroy. `shift_params` permits `penalty_rules_attributes`, so the SEC-M2-3 fix alone would have left penalty rules writable through `PATCH /admin/shifts/:id`. Any admin-gate holder could also create, edit or delete shifts (times drive lateness and overtime) | `view_employees`-only user added a 999 penalty rule through the shift form, changed a shift's start time, created and deleted shifts |
| SEC-M2-8 | Low–Medium (code-evident) | `Admin::BiometricPunchLogsController` | No `authorize`; business-wide punch logs (employee, time, IP address) for any admin-gate holder, with no data scope | Code reading |

### 5.1 Security hardening before Pilot 1 (fixed)

**Why these are separate from the migration:** a security fix changes behaviour (who may do what), while a migration
step must be behaviour-preserving and mechanical (`migration-pattern.md` §9: never mix defect fixes with migration
steps). Each fix is therefore its own `fix:` commit:

* It is fixed **before** Pilot 1's characterization, so M1 pins the corrected behaviour, not the vulnerable one.
* It can be reviewed and reverted independently.
* It is never mixed into the later `refactor:` move commit.

Shared rules:

* No new permission and no new authorization mechanism: existing policies (or one new policy using an existing
  permission) are called with Pundit `authorize` / `policy_scope`.
* Lookups stay inside `current_user.business` (another business → 404).
* No route, API, schema or migration change.

**Proof that each spec catches its defect:** every regression spec was run against the previous code, where its
attack cases fail, and against the fix, where all pass.

| ID | What was wrong | Fix | Commit | Regression coverage | Valid behaviour preserved |
|---|---|---|---|---|---|
| **SEC-M2-1** | `Admin::BiometricDevicesController` had no policy. Any admin-gate holder (`view_employees`, `view_attendance`, `view_payroll`, …) could list devices, read or regenerate a device token, and create, edit or delete devices. A token authenticates the punch API for any employee of the business | New `BiometricDevicePolicy`: every action (index/show/new/create/edit/update/destroy/regenerate_token) requires the existing `manage_devices` permission within the device's business; `authorize` in every action | `28b2100` | `spec/requests/security/biometric_devices_authorization_spec.rb` (15): every action denied without `manage_devices` (token never rendered); the full lifecycle with `manage_devices`; cross-business 404 for view/update/regenerate/delete; owner access | A `manage_devices` holder and the owner keep the full lifecycle; the device list shows only the business's devices; the punch API and its characterization are unchanged |
| **SEC-M2-2** | `PATCH /admin/attendance_records/:id` had no policy and a business-wide lookup. Any admin-gate holder could rewrite any employee's — or their own — check-in/check-out (pay is recalculated). Index and show ignored the data scope | `Admin::AttendanceRecordsController` now uses `policy_scope(AttendanceRecord)` + `AttendanceRecordPolicy`, exactly like the policy-based `AttendanceRecordsController`: business + `view_attendance` data scope for the lookup, `manage_attendance` for the change. The edit form renders only when `update?` is allowed. The non-admin `PATCH /attendance_records/:id` was already protected and is unchanged | `ca66c43` | `spec/requests/security/admin_attendance_records_authorization_spec.rb` (9; 5 fail on the old code): no change without `manage_attendance` (other employee and own record); business-scope manager can change; branch scope limits change and listing to the managed branch (other branch → 404); another business's record → 404 even for the owner | Same-business, in-scope `manage_attendance` holders change records exactly as before; viewers still see in-scope records (read-only) |
| **SEC-M2-3** | `Admin::PenaltyRulesController` called no policy. Any admin-gate holder could create, edit or delete payroll penalty rules | Every action (new/create/edit/update/destroy) authorizes with the existing `PenaltyRulePolicy` (`manage_shifts`); rules are reachable only through a shift of the actor's business | `3d9127e` (with SEC-M2-9) | `spec/requests/security/admin_shifts_and_penalty_rules_authorization_spec.rb` (26 in total; 13 fail on the old code): forms/create/update/delete denied for `view_shifts` and `view_employees`-only users; `manage_shifts` lifecycle; foreign shift/rule → 404, including a foreign rule through an own shift's URL | `manage_shifts` holders and the owner create, update and delete rules as before |
| **SEC-M2-9** | `Admin::ShiftsController` called no policy. Shifts, and penalty rules via `penalty_rules_attributes`, were writable by any admin-gate holder | Every action authorizes with the existing `ShiftPolicy` (view: `view_shifts`/`manage_shifts`/`assign_shifts`; change: `manage_shifts`). The index keeps its own query (`ShiftPolicy::Scope` would hide inactive shifts). The admin shift pages render change actions only when the policy allows them | `3d9127e` (with SEC-M2-3) | Same spec: the demonstrated attack (`view_employees`-only `PATCH /admin/shifts/:id` with a new name/time or with nested rules added, changed or removed) is denied; create (with nested rules), update, destroy and the forms are denied; `view_shifts` is read-only; `manage_shifts` create/update (incl. nested rules)/delete; another business's shift → 404 | `manage_shifts` holders keep shift + nested penalty-rule editing; `view_shifts` / `assign_shifts` holders keep read access |
| **SEC-M2-4** | `EmployeeObligation` (a payroll deduction) accepted a `user_id` of another business, and `Payroll::ObligationDeductor` selected obligations by user only, so business B's payroll would deduct an obligation recorded in business A | `EmployeeObligation` validates that `user` and `created_by` belong to its business (SEC-P3-1 pattern; validated only when a reference changes, so existing rows are not re-validated). This covers create (422) and update via `Payroll::ObligationEditor` (422). `ObligationDeductor` applies only obligations of the period's business, so a foreign row created before the fix is never deducted. The factory defaults to same-business references | `a384319` | `spec/requests/security/employee_obligations_business_scope_spec.rb` (9; the 4 attack cases fail on the old code): foreign `user_id` rejected on create and update (nothing created or changed); model rejects a foreign user and creator; a legacy foreign obligation is not deducted | Same-business create and edit still work; a same-business obligation is still deducted (asserted); the employee picker is unchanged |

**Verification of the hardening (focused sets; the full suite has not been run yet):**

* **After SEC-M2-3 + SEC-M2-9:** 1,263 examples.
* **After SEC-M2-4:** 1,668 examples.
* **Comparison:** every failing ID is in `attendance-payroll-baseline-failures.txt` /
  `permission-role-baseline-failures.txt`, so there are **0 new failures**.
* `zeitwerk:check` passes, `git diff --check` is clean, and RuboCop reports no offenses in any changed file. The
  project-wide count is 370, all pre-existing; `c054fa3` had 372, and SEC-M2-1 fixed 2 on a touched line.

**Final state of the attendance-admin surface:** every AP admin controller now calls `authorize` except
`Admin::BiometricPunchLogsController` (SEC-M2-8, read-only, deferred). `Admin::DashboardController` (a read-only
overview) also has none; it is outside this hardening.

### 5.2 Deferred findings (recorded follow-up, not fixed)

| ID | Severity | Item | Why deferred / follow-up |
|---|---|---|---|
| SEC-M2-5 | Medium | Employee page shows salary and obligations without the AP policies | Needs Q-M2-5 (AP policy gate in the WF view vs AP-contributed panel) |
| SEC-M2-6 | Medium | Salary-profile create/update ignores the `manage_salary_profiles` scope; self-salary changes allowed | Needs Q-M2-4 (segregation-of-duties rule) |
| SEC-M2-7 | Medium | Advance and salary-profile scopes ignore the configured `view_payroll` scope | Needs a scope decision; fix before P-3 / P-6 |
| SEC-M2-8 | Low–Medium | Punch logs visible business-wide to any admin-gate holder | Needs Q-M2-2; it is in Pilot 1's scope (CG-4), so it should be decided before Pilot 1's M1 |
| AP-D1 | Defect (not security) | `GET /api/v1/users/:id/salary_profiles` raises `NoMethodError` for callers without salary/payroll permission | Fix with SEC-M2-6/7 (same policy) |
| SEC-M2-4 follow-up | Medium (product decision) | Obligation creation is not limited to the creator's `manage_obligations` data scope; the employee picker is intentionally business-wide | Decide with P-2 (Obligations) |
| SEC-M2-2 follow-up | Low (product decision) | Admin and web attendance updates both use the `view_attendance` scope for the lookup (not the `manage_attendance` scope), and allow a `manage_attendance` holder to edit their own record — the existing web-path rule, kept for parity | Decide with P-7 (Attendance records) |

**Related defects (not security):**

* **AP-D1:** `GET /api/v1/users/:id/salary_profiles` raises `NoMethodError` (`SalaryProfilePolicy#viewable?` →
  `own_record?` on the **class**) for any caller without `manage_salary_profiles` / `view_payroll`. This breaks the
  CLAUDE.md rule on class records. Proven by probe.
* **AP-D2:** `Api::V1::PayrollLineItemsController#waive` calls the removed `waive?` (already pinned as D1 in the
  API characterization; a baseline failure).

**Checked and found sound:** web payroll period, entry, line-item and adjustment lookups all go through
`policy_scope` with per-action policies. `Adjustments::BulkCreateService` enforces `allowed_user_ids`.
`PayrollAdjustment` validates the same business. The device API rejects inactive devices, a missing token and
employees outside the device's business (characterized). No AP code writes WF or OA tables.

## 6. Candidate pilot groups (scored with `migration-pattern.md` §12; 1 = best, 3 = worst)

| Criterion (weight) | P-1 Punch capture | P-2 Obligations | P-3 Salary config | P-4 Penalty rules | P-5 Payroll adjustments | P-6 Advances | P-7 Attendance records | P-8 Payroll core |
|---|---|---|---|---|---|---|---|---|
| Coupling (3) | 1 | 2 | 2 | 2 | 2 | 3 | 3 | 3 |
| Callers (2) | 1 | 1 | 2 | 2 | 2 | 2 | 3 | 3 |
| Cross-domain deps (3) | 1 (OA inverse, UI shell) | 2 (WF profile card) | 2 (WF profile card) | 3 (WF nested write, E #4) | 2 (helper, Reporting) | 3 (E #1, cycle F1) | 3 (E #2–#3, F2, Reporting) | 3 (E #5, F3) |
| Security risk (3) | 3 → **2 after SEC-M2-1** | 3 (SEC-M2-4) | 3 (SEC-M2-5/6/7) | 3 (SEC-M2-3) | 2 | 2 (SEC-M2-7) | 3 (SEC-M2-2) | 2 |
| Criticality (2) | 3 | 3 | 3 | 3 | 3 | 3 | 3 | 3 |
| Coverage (2) | 1 (API characterized + 84 service/admin examples) | 1 | 2 | 2 | 2 | 2 | 1 | 1 |
| Database (2) | 1 | 1 | 1 | 1 | 1 | 1 | 2 | 2 |
| Cycles (3) | 1 | 1 | 1 | 2 | 1 | 3 | 3 | 3 |
| Size (1) | 1 (2 models, 565 lines) | 2 (3 models, 1,053 lines) | 1 | 1 | 2 | 1 | 3 | 3 |
| Rollback (2) | 1 | 1 | 1 | 2 | 1 | 2 | 2 | 2 |
| Baseline noise (1) | 1 (0 failures) | 1 (0) | 2 (AP-D1) | 1 | 2 (`adjustments_spec:740`) | 3 (eligibility ×3) | 3 (API attendance ×7, check-in ×4) | 3 (visibility ×9, waive ×17, approval ×4) |
| **Weighted total** | **31** after SEC-M2-1 (34 before) | 41 | 45 | 52 | 43 | 57 | 64 | 61 |

**Disqualifiers:**

* **P-6 Advances, P-7 Attendance records, P-8 Payroll core:** each sits on an unresolved cross-domain cycle (F1, F2
  and F3).
* **P-4 Penalty rules:** needs a boundary for the WF `Shift` nested write, so standard M2–M5 apply.
* **P-2, P-3, P-4:** each carries an open security defect whose fix needs a product decision (data-scope rules,
  self-salary segregation of duties).

## 7. Selected Pilot 1 — Biometric Device + PunchService (punch capture channel)

**Approved.** Not started.

### 7.1 Exact scope

| Kind | Items |
|---|---|
| Models | `BiometricDevice`, `BiometricPunchLog` |
| Tables | `biometric_devices`, `biometric_punch_logs` |
| Controllers | `Admin::BiometricDevicesController`, `Admin::BiometricPunchLogsController`, `Api::V1::BiometricBaseController`, `Api::V1::PunchesController` |
| Services | `Attendance::PunchService`, `Attendance::TimestampParser` (already in `app/services/attendance/`, so no move is needed) |
| Policies | `BiometricDevicePolicy` (added by the SEC-M2-1 fix, `28b2100`, not by the pilot). There is no punch-log policy yet (SEC-M2-8 deferred) |
| Jobs / queries | None. The punch-log filtering query lives in the admin controller |
| Views | `app/views/admin/biometric_devices/`, `app/views/admin/biometric_punch_logs/` (7 files) |
| Specs | `requests/api/v1/characterization/biometric_punch_spec.rb` (9), `services/attendance/punch_service_spec.rb` (38), `timestamp_parser_spec.rb` (25), `requests/admin/biometric_punch_logs_spec.rb` (12); also exercised by `anomaly_detector_spec`, `csv_importer_spec`, `historical_backfill_spec`, `request_logging_spec`, `sidebar_active_state_spec` |

**Not included:**

* `AttendanceRecord` (P-7; `PunchService` writes it, an internal AP edge).
* `Attendance::AnomalyDetector` (reads punch logs, internal).
* The mobile check-in path in `Api::V1::AttendanceController` (internal writer of rejection logs).
* The `users` attendance-channel flags (G).

### 7.2 Dependencies (M0 fast inventory)

| Kind | Finding |
|---|---|
| Internal (AP) | `AttendanceRecord has_many :biometric_punch_logs`; `PunchService` → `AttendanceRecord`; `AnomalyDetector` and the mobile API read or write `BiometricPunchLog` |
| Cross-domain code callers | **None** |
| Cross-domain references | `Business has_many :biometric_devices / :biometric_punch_logs` (OA inverse, C); `_sidebar` and `workspace_helper` navigation (UI shell, C); `PunchService` → `Shifts::AssignmentResolver` (AP → WF read, allowed) |
| Direct cross-domain writes | **None** |
| Circular dependencies | **None** |
| Database | 0 migrations call the constants (only the two `Create*` migrations); no STI or polymorphic type stores the class names (no `log_audit`, no attachments) |

### 7.3 Security risk

* It was **High** at M0 (SEC-M2-1, SEC-M2-8), because the device token is a credential that writes
  payroll-relevant data.
* **SEC-M2-1 is fixed** (`28b2100`); SEC-M2-8 is deferred (read-only).
* The remaining risk is Medium. That leaves an external-hardware authentication realm that is already characterized (401
  without token, 401 inactive, header alternative, web session ignored, 404 for a foreign employee, 422 for
  timestamp, window and channel).

### 7.4 Characterization gaps (M1, after the security fix)

| Gap | Status |
|---|---|
| CG-1 Device admin authorization matrix: `manage_devices` allowed, admin-gate-only permissions denied, owner allowed, cross-business 404, token visible only to authorized users | **Covered** by the SEC-M2-1 regression spec (`28b2100`) |
| CG-2 Device CRUD + `regenerate_token` contract (redirects, flash, token changes, **old token rejected** by the punch API) | **Covered** by M1 `1024ffb` (`biometric_device_spec`) |
| CG-3 Punch API negatives not yet pinned: unknown token (vs inactive), device of business B with employee of B only, duplicate or stale punch outcome | **Covered** by M1 `1024ffb` (`punch_api_spec`, `biometric_device_spec`) |
| CG-4 Punch-log visibility: who may list and show logs, cross-business 404 on `show` | **Covered as current behaviour** by M1 `1024ffb` (`biometric_punch_log_spec`). SEC-M2-8 is still deferred, so the pinned visibility is labelled as the deferred finding, not as desired behaviour |
| CG-5 `destroy` nullifies logs (`dependent: :nullify`) | **Covered** by M1 `1024ffb` |

### 7.5 Migration complexity, boundary and physical move

* **Complexity:** low (SEC-M2-1 is fixed). The move is byte-identical and keeps the constants and tables.
* **Boundary objects:** **not needed** (no cross-domain caller; rule A/B).
* **Physical move (M7):** appropriate. This would be the **first AP collapsed directory**, so it needs:
  * the Q-M2-1 naming decision;
  * a new `config/initializers/attendance_payroll_autoload.rb`;
  * an AP boundary spec and an AP location spec (both new, following the Workforce pattern).

### 7.6 Why this is the best first pilot

* It is the only AP group with **no cross-domain caller, no cross-domain write, no cycle and no baseline failure**.
* It is already characterized at the API level (the previous selection's C3).
* It is a real business boundary (the capture channel), not a size pick. It establishes AP's enforcement spec and
  collapsed directory for every later group.
* The previous objection to C3 (it preceded Workforce, §19 order) no longer applies, because Workforce has moved.

### 7.7 Why the others wait

| Group | Reason to wait |
|---|---|
| P-2 Obligations | Strong runner-up. It waits for the SEC-M2-4 fix (cross-business plus the scope rule decision) and for a decision on the WF employee-page obligations card (exception vs UI composition). **Recommended Pilot 2** |
| P-3 Salary configuration | SEC-M2-5/6/7 and AP-D1 must be fixed first; the self-salary segregation-of-duties rule needs a product decision |
| P-4 Penalty rules | SEC-M2-3, plus the WF `Shift` nested-attributes write (E #4) needs an interface step (standard M2–M5) |
| P-5 Payroll adjustments | Bound to `PayrollLineItem` (payroll core) through `AdjustmentApplier`; best migrated with or after the payroll core |
| P-6 Advances | WF ↔ AP cycle F1; needs the `employee_request.*` contract (`module-boundaries.md` §14.1 B) |
| P-7 Attendance records | SEC-M2-2, cycle F2, WF writes (E #2–#3), 11 baseline failures |
| P-8 Payroll core | AP → FS write (E #5, cycle F3), largest controller, 30 baseline failures; last |

## 8. Fast-track decision and expected sequence

**Decision: fast track, gated by a security precondition.** M0 found no cross-domain code callers for P-1, so no
boundary or interface is required. M2–M5 are **skipped on evidence**:

* no cross-domain caller (M2/M3);
* the services are already in `app/services/attendance/` (M4);
* the device controllers hold no business rules beyond CRUD (M5). The missing authorization is a **defect fix**,
  not an M5 refactor.

| Order | Fast-track step | Standard IDs | Content | Commit |
|---|---|---|---|---|
| 0 | M0 Fast inventory | M0 | This section + baseline file | `docs:` (this checkpoint) |
| 1 | **Security precondition** | — (defect fix, like SEC-P3-1) | **Done:** SEC-M2-1 `28b2100`, plus SEC-M2-2 `ca66c43`, SEC-M2-3 + SEC-M2-9 `3d9127e` and SEC-M2-4 `a384319` (§5.1). SEC-M2-8 is still to be decided before M1 (CG-4) | `fix:` ×4 (done) |
| 2 | M1 Characterization | M1 | **Done** (§13): CG-2 to CG-5 against the fixed code; default and random order | `test:` `1024ffb` |
| 3 | M2 Boundary + M6 Physical + M7/M8 | M6 + M7 + M8 | **M6 done separately** (§14), per the M6-only approval; M7 + M8 remain. New AP boundary spec (constants `BiometricDevice` / `BiometricPunchLog`, tables, allow-list: `Business` inverse, sidebar, `workspace_helper`, AP-internal writers) with a probe; `git mv` of the 2 models into the collapsed AP directory + initializer + location spec; verification + status section | `refactor:` (one commit, as in Pilot 3) |

**Database verification (M8):** not needed. No migration calls the constants, and no class names are stored.

**Other security fixes:**

* SEC-M2-2, -3, -4 and -9 are fixed (§5.1).
* SEC-M2-5 to -8 and AP-D1 are deferred (§5.2). Each must be scheduled as a separately approved `fix:` commit before
  the pilot that touches it.

## 9. Test baseline (Step 9)

* **Recorded:** 2026-10-06, at `c054fa3`, with no code changes. The file list and the full failing-ID list are in
  `attendance-payroll-baseline-failures.txt`.
* **Set:** 140 spec files:
  * AP core (111): AP models/policies, `spec/services/{attendance,payroll,salary,adjustments}`, AP reports,
    `employee/performance_scorer`, AP request/API/characterization/standard-contract/system specs,
    `scenarios/multi_branch_payroll_cycle`, `dashboard_spec`;
  * Workforce ↔ AP (19): `services/requests`, `employee_request*`, `api/v1/employee_request*`,
    `admin/employee_insurance_profiles`;
  * `spec/architecture` (4);
  * `spec/requests/security` (6).
* **Result:** 2,634 examples, **52 failures**, 1 pending.
* **ID comparison:** all 52 are already in `permission-role-baseline-failures.txt`, so there are **0 new failures**.

| File | Failing IDs | Note |
|---|---|---|
| `requests/api/v1/payroll_waive_scope_spec.rb` | 17 | Pre-existing (AP-D2 family) |
| `requests/api/v1/payroll_visibility_spec.rb` | 9 | Pre-existing |
| `requests/api/v1/attendance_spec.rb` | 7 | Pre-existing |
| `services/attendance/check_in_service_spec.rb` | 4 | Business-day boundary |
| `requests/payroll_review_approval_paths_spec.rb` | 4 | Pre-existing |
| `services/salary/advance_eligibility_calculator_spec.rb` | 3 | Date-dependent; `:208` passed today (flaky, TD-AP1) |
| `policies/operations_dashboard_policy_spec.rb` | 3 | Pre-existing |
| `requests/dashboard_spec.rb` | 2 | Pre-existing |
| `requests/adjustments_spec.rb`, `policies/payroll_period_policy_spec.rb`, `models/employee_request_spec.rb` | 1 each | Pre-existing (`employee_request_spec:432` is date-dependent) |

* **Pilot 1 scope files have 0 failing IDs.**
* **Architecture and security specs:** all green.
* **Not run:** the full suite, migrations and any destructive task.

## 10. Known technical debt (recorded, not fixed)

| ID | Item |
|---|---|
| TD-AP1 | Date-dependent advance-eligibility and employee-request specs (`advance_eligibility_calculator_spec:198/208/253/264`, `employee_request_spec:432`) |
| TD-AP2 | Biometric device create / regenerate-token / destroy write **no audit log** (audit-first rule); a behaviour change, so it needs its own decision |
| TD-AP3 | `Admin::AttendanceRecordsController` duplicates `AttendanceRecordsController`. Since SEC-M2-2 it uses the same policy; it remains to decide whether the legacy path should exist (Q-M2-3) |
| TD-AP4 | `SalaryProfile` `update` edits the active profile in place (CLAUDE.md "corrections are append-only"); the API restricts the fields, the web path does not |
| TD-AP5 | Two branch-membership paths inside AP (DS-7) |
| TD-AP6 | `PayrollPeriodsController` (543 lines) holds orchestration that belongs in services; a prerequisite for P-8 |
| TD-AP7 | `Api::V1::PayrollAdjustmentsController#create` authorizes the class; `same_business?` on a class passes only for owners, so non-owner managers are always denied (functional, not a leak) |
| TD-AP8 | Deferred security follow-ups (§5.2): SEC-M2-5, -6, -7, -8, AP-D1, plus the SEC-M2-4 and SEC-M2-2 scope decisions |
| **AP-D3** | **Known defect, found during Pilot 1 M1 characterization (§13).** When a work date's attendance record was soft-deleted (`deleted_at`), a later punch for that date updates the deleted record (`AttendanceRecord.find_or_initialize_by` has no `active` filter; the unique `(user_id, work_date)` index prevents a new row). The punch reports success while the attendance stays invisible (`AttendanceRecord.active` excludes it). It is **not a regression** caused by M1 (pre-existing production behaviour) and is **not classified as a security vulnerability**. **Pinned, not fixed:** `spec/characterization/attendance_payroll/punch_service_spec.rb`. A fix changes production behaviour and needs its own approved `fix:` commit |
| **TD-OA1** | **Flaky test-data failure** (same treatment as TD-PERF1 / TD-FIN1), observed in the Pilot 1 M8 verification run: `spec/characterization/organization_access/permission_roles_spec.rb:28`. Faker generated the user name "Unassigned O'Reilly"; the page HTML-escapes the apostrophe while the spec checks the plain-text name literally. Pre-existing and data-dependent: it passed 6/6 isolated reruns and 14/14 for the whole file, and passed in the M8 rerun. Milestone 2 touched neither the PermissionRole controller/views nor the user factory, so there is no production regression. Recorded as `flaky` in `attendance-payroll-baseline-failures.txt`; not fixed |
| **AP-D4** | **Fixed** in `6177e8b` before Pilot 2 M1 (§17): pause and cancel did not rebuild open payroll, so the draft kept deducting the obligation |
| **AP-D5** | **Fixed** in `b6d4526` before Pilot 2 M1 (§17): reassignment left the previous employee's draft deduction, a double deduction |
| **TD-AP9** | Obligation pause / resume / cancel change status in `Admin::EmployeeObligationsController`, with no service, no audit log and no reason captured (CLAUDE.md "never bypass services", "every financial action must generate an audit event", "destructive actions require a reason"). The AP-D4 fix added only the atomic open-payroll rebuild. A fix changes behaviour and needs its own approved commit |
| **TD-AP10** | The obligation installment-count rule is duplicated (`Admin::EmployeeObligationsController#derive_installments_count` and `Payroll::ObligationEditor#derive_installments_count`), and create-time derivations (remaining balance, count, business, creator) live in the controller |
| **TD-AP11** | Obligation money arithmetic uses `Float` (`EmployeeObligation#installment_for_period`, `#installment_schedule`, `#repaid_amount`, `#percent_repaid`, `#final_installment_amount`; the controller and editor count derivations). The columns are `decimal(12,2)`, but CLAUDE.md requires no floats for money |
| **TD-AP12** | `employee_obligations.remaining_amount` is a stored, mutable balance kept in step by `ObligationDeduction` before_create / before_destroy callbacks (`repay!` / `restore!`), not derived from the deduction rows. CLAUDE.md: "do not store a separate balance column that drifts from the ledger". No drift was observed; a redesign is a separate decision |
| **FS-D1** | **Fixed** in `f88e022` before Expenses M1 (§18): reopening a finalized payroll left the insurance Expense active, so re-finalizing kept the stale amount |
| **TD-FIN2** | **Flaky test-data failure** (TD-FIN1 pattern): `spec/requests/finance/reports_expense_details_spec.rb:84`. Faker name "Margurite O'Connell" is HTML-escaped while the spec checks plain text. 6/6 isolated, 17/17 file. Recorded as `flaky` in `attendance-payroll-baseline-failures.txt`; spec unchanged |
| **FS-D2** | **Fixed** in `94c4dce` before Expenses M1 (§18.5): the insurance generator looked the "Social Insurance" category up case-sensitively, so an existing "social insurance" category made payroll finalization fail |
| **TD-FIN3** | **Flaky browser-timing failure**: `spec/system/finance/expense_duplicate_branch_spec.rb[1:2]` and, in the same distribution-method loop, `[1:1]`. Right after "add row", `all(...)` does not wait, so the new row may not exist yet. `[1:2]`: 6/6 isolated, passed at M0 and after the FS-D1 commit. `[1:1]`: failed once in 6 isolated reruns with no code change involved; the whole file passed 4/4. No view/JS changed. Recorded as `flaky`; spec unchanged |
| **TD-FIN4** | **Flaky browser-timing failure**: `spec/system/finance/expense_register_payment_spec.rb:27`. The payment was recorded but the custody balance stayed 0 instead of −400, i.e. the "paid from balance" checkbox may not have been registered before submit. 6/6 isolated, whole file passed; no Finance view/JS/payment code changed. Recorded as `flaky`; spec unchanged |
| **FS-D3** | **Open defect, found in Pilot 3 M8 (§18.8)**, the FS-D2 pattern in Finance-internal POS code outside the migrated insurance path: `Finance::PosImports::ExpenseGenerator` (`app/services/finance/pos_imports/expense_generator.rb:35`) finds the "Payment Gateway Fees" category with a case-sensitive `find_or_create_by!`, while `ExpenseCategory` names are unique per business case-insensitively. An existing "payment gateway fees" category makes the create fail ("Name has already been taken"); `Importer` raises `ExpenseGenerationFailed` and the whole POS import rolls back. Proven with a throwaway probe (exact case reused; different case → `ok: false`). Not security. Needs its own approved `fix:` commit (case-insensitive lookup, as in FS-D2) with a regression spec; not fixed |
| **TD-FIN5** | **Flaky browser-timing failure** (TD-FIN3 / TD-FIN4 treatment), found in the Milestone 2 final full-suite gate (§18.9): `spec/system/finance/deposit_responsibility_transfer_spec.rb:208`. After the recipient's rejection, the manager's DR page did not yet show `#transfer-deposit-responsibility-button` when asserted (Arabic, 430px). Failed on the branch, passed on `main` in the same-seed run; 6/6 isolated, 3/3 whole file; no deposit-responsibility / reconciliation code, view, JS, helper or layout changed in Milestone 2. Recorded as `flaky` in `attendance-payroll-baseline-failures.txt`; spec unchanged |
| Existing | AP-D2 (`waive?`), MIG-1, MIG-2, TD-FIN1, TD-PERF1, TD-ST1, R-L4 (unchanged) |

## 11. Open architectural questions

| # | Question |
|---|---|
| Q-M2-1 | **Resolved** (§14): `BiometricDevice` and `BiometricPunchLog` are AP-owned. The M7 physical move uses the collapsed `app/models/attendance_payroll/`, keeping the constants top-level (no `AttendancePayroll::` namespace), as for Organization & Access and Workforce |
| Q-M2-2 | **Resolved** (§14): `BiometricPunchLog` is AP-owned; its authorization and visibility belong to AP and use the existing attendance permission/scope model. No permission redesign now; SEC-M2-8 stays deferred exactly as documented (§5.2) |
| Q-M2-3 | After SEC-M2-2 (now gated like `AttendanceRecordsController`): keep `Admin::AttendanceRecordsController`, or retire it in favour of `AttendanceRecordsController`? |
| Q-M2-4 | SEC-M2-6: may a salary manager change their **own** salary (segregation of duties), and should `manage_salary_profiles` scope apply to the web path? |
| Q-M2-5 | Employee-page salary and obligations cards (SEC-M2-5): gate them with AP policies inside the WF view (exception), or render them as an AP-contributed panel (UI composition, `module-boundaries.md` §12.1)? |
| Q-M2-6 | Should `BiometricPunchLog` be documented as the channel-neutral "punch log" (DS-8)? Naming only; the constant stays |
| Q-P3-1 | `Employee::PerformanceScorer` ownership (carried over) |

## 12. Status

* **Done:**
  * M0 audit, security audit and Pilot 1 selection (approved: Biometric Device + PunchService).
  * Security hardening: SEC-M2-1 `28b2100`, SEC-M2-2 `ca66c43`, SEC-M2-3 + SEC-M2-9 `3d9127e`, SEC-M2-4
    `a384319`; final security verification passed (no new failure IDs).
  * Pilot 1 M1 characterization: `1024ffb` (§13).
* **Pilot 1 M6 (boundary enforcement):** done (§14).
* **Pilot 1 M7 (physical model move):** done (§15).
* **Pilot 1 M8 (final verification and close-out):** done. **Pilot 1 is COMPLETE** (§16).
* **Pilot 2 (Employee Obligations):** **COMPLETE** (§17).
* **Milestone 2 — Finance & Sales Expenses (Pilot 3):** **COMPLETE** (§18, close-out §18.8). SEC-M2-12
  (`6b4d300`), FS-D1 (`f88e022`) and FS-D2 (`94c4dce`) fixed; M1 `98edd8e`, M2 `4b94668`, M3 `d009f0d`, M4 `0ca2dc5`,
  M6 `ddaceb1`, M7 `ee47554`, M8 docs; M5 not needed. FS-D3 open (§10).
* **Pilot 4 — Attendance & Payroll Penalty Rules:** **COMPLETE** (§19, close-out §19.12). M0 `b73fc34`, M1 `3efb46b`,
  M2 `40e5ed0`, M3 `4d7ae92`, M4 `a2ae7aa`, M6 `3fd9ba2`, M7 `a3b6463`, M8 `ce3ce00`; M5 not needed. P4-D1 open
  (§19.11).
* **Pilot 5 — Organization & Access ↔ Workforce membership contract:** on `feature/pilot-5-membership-contract`
  **COMPLETE** (from `main` @ `3be2816`, not pushed): M0 done (read-only), M1 `114f771`, M2 `69031c1`, M3 `5d6b454`,
  M4 / M5 not needed, M6 `1b5cd65`, M7 not needed, M8 docs (§20.6).
* **Pilot 6 — Inventory & Purchasing Supplier:** **COMPLETE** on the same branch (on top of Pilot 5, not pushed): M0,
  security unblock (SEC-P6-1 – SEC-P6-6 fixed), M1 `bfbb88b`, M2 – M5 not needed, M6 `b34d959`, M7 `3348fbf`, M8 docs
  (§21.8). No next pilot started.
* **Pushed, not merged:** `feature/milestone-2-attendance-payroll` is on origin at `b28110f` (pushed after the §18.9
  gate). The Pilot 4 commits are on `feature/pilot-4-penalty-rules` (a fast-forward of `b28110f`, not pushed) and are
  to be included in the milestone branch before the PR (§19.13).
* **Q-M2-1 and Q-M2-2:** resolved (§14).

## 13. Pilot 1 — Biometric Device + PunchService: M1 characterization status (complete)

**Status:** **COMPLETE.**

* **Commit:** `1024ffb` "test: characterize attendance biometric flow".
* **Production code:** unchanged at this step. No database, schema or migration changes, no models moved.
* **M6/M7 have NOT started.**

**Scope:**

* **Characterized:** `BiometricDevice`, `BiometricPunchLog`, `Attendance::PunchService`,
  `Attendance::TimestampParser`, and their directly owned controllers:
  * `Admin::BiometricDevicesController`, `Admin::BiometricPunchLogsController`;
  * `Api::V1::PunchesController` / `BiometricBaseController`;
  * the mobile rejection log written by `Api::V1::AttendanceController`.
* **Not expanded:** no other component was added.

**Existing coverage (inventoried before writing specs; not duplicated):**

* `punch_service_spec`: 38 examples.
* `timestamp_parser_spec`: 25.
* API `biometric_punch_spec`: 9.
* `admin/biometric_punch_logs_spec`: 12.
* SEC-M2-1 `biometric_devices_authorization_spec`: 15.

**New characterization:** 59 examples in `spec/characterization/attendance_payroll/`. The folder name organizes
specs only; it does not decide Q-M2-1.

| File | Examples | What it pins |
|---|---|---|
| `biometric_device_spec.rb` | 19 | Model: token generated on create (a supplied token is ignored), unique tokens, `regenerate_token!`, name presence and per-business case-insensitive uniqueness, active default and scopes, logs detached on destroy. Admin: business forced to the actor's, token never assignable, 422 re-render, ordering, flashes. Punch API: unknown, deactivated, regenerated and deleted tokens → 401; `last_seen_at` touched only on success |
| `biometric_punch_log_spec.rb` | 8 | `ACTIONS` / `SOURCES`, required fields, `success?` / `rejected?` table, scopes and recency, the mobile `rejected_not_allowed` log. Admin visibility **as-is** (SEC-M2-8 deferred): any admin-gate holder sees all business logs; users without an admin-gate permission are redirected; another business's log → 404 |
| `punch_api_spec.rb` | 13 | `employee_code` before user id; inactive or blank employee → 404 without a log; employee checked before timestamp; missing or > 24 h future timestamp → 422; bare timestamps read in business-local time; check-in and check-out payloads; duplicate punch → 200 `rejected_spam`; unassigned employee → 422 + log; logged device, IP address and raw payload |
| `punch_service_spec.rb` | 10 | Spam-window membership: other devices, mobile, `rejected_spam` and `rejected_not_allowed` count; `rejected_no_assignment` and `error` do not; symmetric; per business. A punch equal to the check-out is spam. Late check-in refinement (`late_minutes` reset, status kept until check-out). Rejection log shape. **AP-D3 pinned** |
| `timestamp_parser_spec.rb` | 9 | Business-zone result, whitespace, `+HHMM` and fractional `Z`, date-only / time-only, slash and day-first formats, epoch seconds and impossible dates → `nil`, `api` / unknown sources, non-string input |

**Verification:**

* **Baseline before the new specs** (17 existing Pilot 1 files): 476 examples, 10 failures. All 10 IDs are in the
  documented baselines:
  * `api/v1/attendance_spec` ×7;
  * `sidebar_active_state_spec:215/293`;
  * `shift_assignment_spec:7`.
* **After:** 535 examples. The **same 10 failing IDs**, so there are **0 new failure IDs**.
* **Random order:** the 59 new examples pass in default order and with seeds 12345, 98765 and 63339.
* **Wider run** (characterization, security and architecture): 578 examples, 0 failures, 1 pending (the existing
  pinned API `waive?` example).
* `zeitwerk:check` passes; RuboCop reports no offenses in the new files; `git diff --check` is clean.

**Known defect found:** **AP-D3** (§10). A punch on a work date whose attendance record was soft-deleted updates that
record and reports success, while the attendance stays invisible.

* It is pre-existing behaviour, not a regression caused by M1.
* It is not classified as a security vulnerability.
* It is pinned, not fixed.

**No new security vulnerability** was found during M1.

**Next (not started, needs approval):** the fast-track M6 + M7 + M8 step (§8, row 3). It requires the Q-M2-1
(folder name) and Q-M2-2 (SEC-M2-8) decisions first.

## 14. Pilot 1 — Biometric Device + PunchService: M6 boundary enforcement status

**Status:** M6 only.

* **Done:** the boundary enforcement spec, `spec/architecture/attendance_payroll_biometric_boundary_spec.rb`, the
  **first Attendance & Payroll boundary spec**.
* **Not started:** M7, so no model moved, no initializer and no location spec. The location spec is created
  together with the move in M7, as in Pilots 2 and 3.
* **Unchanged:** production code, database, schema, routes and API.

**Decisions (approved before M6):**

* **Q-M2-1:** the four Pilot 1 classes are AP-owned. M7 moves the two models into the collapsed
  `app/models/attendance_payroll/` and keeps the constants top-level (`BiometricDevice`, `BiometricPunchLog`).
* **Q-M2-2:** punch-log authorization and visibility belong to AP and use the existing attendance permission/scope
  model. SEC-M2-8 remains deferred (§5.2).

**Guarded:**

* the constants `BiometricDevice`, `BiometricPunchLog`, `PunchService` (`Attendance::PunchService`) and
  `TimestampParser` (`Attendance::TimestampParser`);
* the collections and tables `biometric_devices` and `biometric_punch_logs`.

**Not guarded, deliberately:**

* `BiometricDevicePolicy`;
* route helpers (`admin_biometric_devices_path`, …);
* the `users` attendance-channel flags (`allow_biometric_attendance`);
* the `"biometric_device"` check-in source string;
* `includes(:biometric_device)`;
* `config/` (routes, locales), as in the existing boundary specs.

**Reference inventory (repository evidence; comments excluded).** 24 files reference the guarded names. Every one is
classified; there are no unclear references.

| Classification | Files | Reason |
|---|---|---|
| 1. AP internal (allowed) | `app/models/biometric_device.rb`, `app/models/biometric_punch_log.rb` | The models |
| 1. AP internal | `app/models/attendance_record.rb` | `has_many :biometric_punch_logs` (AP aggregate) |
| 1. AP internal | `app/controllers/admin/biometric_devices_controller.rb`, `app/controllers/admin/biometric_punch_logs_controller.rb`, `app/views/admin/biometric_devices/` (5 files), `app/views/admin/biometric_punch_logs/` (2) | AP administration screens |
| 1. AP internal | `app/controllers/api/v1/biometric_base_controller.rb`, `app/controllers/api/v1/punches_controller.rb` | Device-token realm and punch endpoint |
| 1. AP internal | `app/controllers/api/v1/attendance_controller.rb` | AP mobile attendance; writes the mobile `rejected_not_allowed` punch log |
| 1. AP internal | `app/services/attendance/punch_service.rb`, `timestamp_parser.rb`, `anomaly_detector.rb` | Pilot 1 services; the anomaly detector reads punch logs |
| 2. Valid cross-domain read | — | None found |
| 3. Documented exception | `app/models/business.rb` | Organization & Access inverse `has_many :biometric_devices / :biometric_punch_logs` (same treatment as D-WF6) |
| 3. Documented exception | `app/views/layouts/_sidebar.html.erb`, `app/helpers/workspace_helper.rb` | UI shell navigation (admin path, label key, controller name) |
| 4. Unexpected cross-domain dependency | — | **None** |
| Not scanned | `config/routes.rb`, `config/locales/{en,ar}.yml` | Routing and i18n keys (`config/` is outside the scanned `app` / `lib`) |

* **Workforce, User, Employee, Reporting, Finance & Sales, Inventory & Purchasing:** no references. `User` has no
  association to these classes; punches reach employees through `BiometricPunchLog belongs_to :employee`, an AP →
  OA reference.

**Boundary object:** **none.** There is no cross-domain business caller (rule A/B), so the fast track holds: the
standard M2–M5 steps are skipped.

**Spec mechanics** (same as the Workforce boundary spec):

* scans `app` / `lib` code with comments ignored;
* reasoned allow-list of AP files and directories, plus the 3 exceptions;
* stale-entry checks for both files and directories;
* a regex example that pins what is and is not guarded.

**Probe:** a temporary file planted in `app/services/dashboard/` calling `BiometricPunchLog` and
`Attendance::PunchService` failed the spec. It was removed, and no file remains.

**Verification:**

* `spec/architecture`: 36 examples, 0 failures.
* Architecture, all characterization, security and the Pilot 1 set together: 1,016 examples and 10 failures. They
  are **the same 10 IDs as M1**:
  * `api/v1/attendance_spec` ×7;
  * `sidebar_active_state_spec:215/293`;
  * `shift_assignment_spec:7`.

  All are in the documented baselines, so there are **0 new failure IDs**.
* `zeitwerk:check` passes; RuboCop reports no offenses; `git diff --check` is clean.

**Next (needs approval):** M7 physical move and M8 verification:

* `git mv` of the two models into `app/models/attendance_payroll/`;
* a new `config/initializers/attendance_payroll_autoload.rb`;
* an AP location spec;
* the allow-list paths updated in the same commit.

## 15. Pilot 1 — Biometric Device + PunchService: M7 physical organization status

**Status:** M7 only, done; **M8 has not started.** The commit is "refactor: organize attendance payroll biometric
models" (its hash is reported in the M7 report; a commit cannot record its own hash).

**Move** (`git mv`, **byte-identical**: same git blob before and after):

* `app/models/biometric_device.rb` → `app/models/attendance_payroll/biometric_device.rb` (blob `d786f13`).
* `app/models/biometric_punch_log.rb` → `app/models/attendance_payroll/biometric_punch_log.rb` (blob `659e0b1`).

**Constants and tables (unchanged):**

* `BiometricDevice` → `biometric_devices`; `BiometricPunchLog` → `biometric_punch_logs`. Both stay top-level.
* There is no `AttendancePayroll` constant (`defined?(AttendancePayroll)` is `nil`), as decided in Q-M2-1.

**Autoload:**

* New `config/initializers/attendance_payroll_autoload.rb`, one line: it collapses `app/models/attendance_payroll`.
* It mirrors `organization_access_autoload.rb` and `workforce_autoload.rb`. A new domain folder needs its own
  collapse; there is no shared initializer to reuse.

**Architecture specs:**

* **Boundary spec** (`attendance_payroll_biometric_boundary_spec.rb`): only the two model allow-list paths changed,
  to the new location. The M6 rules, exceptions and guarded names are unchanged.
* **New location spec** (`attendance_payroll_model_location_spec.rb`, 10 examples) checks, for each model:
  * it loads as a top-level constant from `app/models/attendance_payroll/`;
  * the old top-level file is gone;
  * its table is unchanged;
  * it is not namespaced under `AttendancePayroll`.

  It also checks that every association resolves the same classes: `Business`, `AttendanceRecord`, the device ↔
  log pair, `employee` → `User`, `attendance_record`. And that Pundit still finds `BiometricDevicePolicy`.

**References** (no code change needed; all resolve to the same top-level classes):

* `Business` and `AttendanceRecord` associations;
* the admin and API controllers;
* `PunchService`, `TimestampParser`, `AnomalyDetector`;
* the mobile `Api::V1::AttendanceController`;
* the navigation helpers;
* `BiometricDevicePolicy`.

**Verification:**

* `spec/architecture`: 46 examples, 0 failures.
* **Relevant set:** architecture, all characterization, all security, `spec/services/attendance`, the Pilot 1 set,
  attendance record model/policy/requests, user model, admin users, attendance imports, dashboard and
  operations-dashboard policy.
  * **Post-move:** 1,479 examples, 19 failures.
  * **Same set at the pre-move commit `8eac847`** (temporary worktree, removed): 1,469 examples, 19 failures.
  * The failing IDs are **identical**, and the +10 examples are the new location spec.
* **Every failing ID is in the documented baselines:**
  * `api/v1/attendance_spec` ×7;
  * `check_in_service_spec` ×4;
  * `operations_dashboard_policy_spec` ×3;
  * `dashboard_spec` ×2;
  * `sidebar_active_state_spec:215/293`;
  * `shift_assignment_spec:7`.
* `zeitwerk:check` passes (eager load resolves both from `app/models/attendance_payroll/`); RuboCop reports no
  offenses; `git diff --check` is clean.

**Database:** not touched. The constants and tables are unchanged, no migration calls the constants, and no class
name is stored, so database verification is not needed (§8, M8).

## 16. Pilot 1 — Attendance & Payroll Biometric (Biometric Device + PunchService): COMPLETE

**Status: COMPLETE** (M8 close-out).

**Sequence (fast track):**

| Step | Result | Commit |
|---|---|---|
| M0 inventory + baseline | Done (§1–§9; `attendance-payroll-baseline-failures.txt`) | `3d746a3` (docs) |
| Security precondition | SEC-M2-1, SEC-M2-2, SEC-M2-3 + SEC-M2-9, SEC-M2-4 fixed | `28b2100`, `ca66c43`, `3d9127e`, `a384319` |
| M1 characterization | Done: 59 examples (§13) | `1024ffb` |
| M2–M5 | **Skipped on evidence:** no cross-domain business caller (M0, confirmed by the M6 inventory), services already in `app/services/attendance/`, no business rules in controllers to extract | — |
| M6 boundary enforcement | Done (§14): first AP boundary spec, no unexpected dependency, no boundary object | `8eac847` |
| M7 physical move | Done (§15): byte-identical `git mv` into the collapsed `app/models/attendance_payroll/` | `bea07f8` |
| M8 verification + docs | Done (this section) | this commit |

**Final state:**

* `BiometricDevice` and `BiometricPunchLog` load as top-level constants from `app/models/attendance_payroll/`. The
  old top-level files are gone, there is no `AttendancePayroll` constant, and the tables `biometric_devices` and
  `biometric_punch_logs` are unchanged.
* **No semantic model change:** only physical organization (same git blobs).
* No database, schema or migration change, and no API or route change.
* **The Attendance & Payroll collapsed-folder pattern is validated:** one-line
  `config/initializers/attendance_payroll_autoload.rb`, as for Organization & Access and Workforce.

**M8 verification:**

* **Location:** confirmed by the location spec and a runtime check. The constants, source paths and table names
  match, `defined?(AttendancePayroll)` is `nil`, and both tables exist.
* **Architecture:** 46 examples, 0 failures.

  | Spec | Examples |
  |---|---|
  | AP boundary | 4 |
  | AP location | 10 |
  | PermissionRole boundary | 3 |
  | PermissionRole location | 4 |
  | Workforce boundary | 3 |
  | Workforce location | 22 |

  * The Organization & Access and Workforce architecture specs are unchanged since `c054fa3`.
  * The only change to the AP allow-list since M6 is the two model paths (the move); no rule or exception was
    weakened, and every documented exception remains.
* **Security:**
  * `spec/requests/security`: 193 examples, 0 failures. This includes SEC-M2-1 (15), SEC-M2-2 (9),
    SEC-M2-3 + SEC-M2-9 (26), SEC-M2-4 (9), and the Organization & Access and Workforce (performance,
    shift-assignment) security specs.
  * `spec/requests/api/v1/security`: 24 examples, 0 failures.
* **Characterization** (all, including API and the Pilot 1 specs): 329 examples, 0 failures, 1 pending (the
  existing pinned API `waive?` example).
* **Final verification set:** 182 spec files — the 140-file M0 set, plus:
  * architecture, characterization, API characterization and security specs;
  * the Pilot 1 set;
  * attendance / payroll / salary / reports services;
  * shift, penalty-rule and obligation specs;
  * admin users and the user model.

  Result: **3,489 examples, 59 failures, 1 pending.**
* **Comparison by ID:**
  * **All 52 IDs** in `attendance-payroll-baseline-failures.txt` still fail as recorded, and none started passing.
  * The other 7 are in `permission-role-baseline-failures.txt`: `shift_assignment_spec:7`,
    `shift_templates_spec:204`, `permission_matrix_verification_spec:502/508/556`,
    `sidebar_active_state_spec:215/293`.
  * **0 new failure IDs.**
* **TD-OA1:** in the first M8 run (60 failures), `permission_roles_spec.rb:28` failed outside every baseline. It was
  investigated, found to be data-dependent (§10), and recorded as `flaky` after review. It passed in the rerun.
  It is the only flaky ID observed.
* `zeitwerk:check` passes; RuboCop reports no offenses (10 Pilot 1 Ruby files; 22 Milestone 2 Ruby files);
  `git diff --check` is clean.

**Carried forward (not fixed):**

* **AP-D3:** known defect, pinned, not fixed (§10).
* **SEC-M2-8:** deferred, as documented (§5.2), together with SEC-M2-5/-6/-7 and AP-D1.
* **TD-OA1:** flaky (§10).
* **No new security findings** in M1–M8.

**Next:** Pilot 1 is complete. **Pilot 2 has not started**; it requires a separate selection and review step.
§7.7 records P-2 Obligations as the M0 runner-up, but that is input to the selection, not a decision.

## 17. Pilot 2 — Employee Obligations: COMPLETE

**Status: COMPLETE.**

* **Path:** M0 → M1 → M6 → M7 → M8, plus a security precondition and two payroll-correctness fixes before M1.
* **Pilot 2 commits** (all local on `feature/milestone-2-attendance-payroll`, none pushed): `869cadd`, `6177e8b`,
  `b6d4526`, `c255f5e`, `9298ced`, `77239ce`, and this docs commit.
* **Not changed:** database, schema, migration, route, API and permission model.

### 17.1 Sequence

| Step | Result | Commit |
|---|---|---|
| M0 inventory + baseline | Done (§17.2); selected over the other candidates on evidence (§17.6) | — (recorded here) |
| Security precondition | SEC-M2-10, SEC-M2-11 and the SEC-M2-4 follow-up fixed **before M1** | `869cadd` |
| Payroll-correctness precondition | AP-D4 and AP-D5 fixed **before M1** (not security; correctness) | `6177e8b`, `b6d4526` |
| M1 characterization | 24 examples, no new defect (§17.4) | `c255f5e` |
| M2–M5 | **Skipped on evidence** (§17.5) | — |
| M6 boundary enforcement | 20 references classified; no boundary object (§17.4) | `9298ced` |
| M7 physical move | 3 models into the collapsed `app/models/attendance_payroll/` (§17.4) | `77239ce` |
| M8 verification + docs | This section | this commit |

### 17.2 M0 — Employee Obligations

* **Inventory:**
  * **Models:** `EmployeeObligation`, `ObligationDeduction`, `ObligationPostponement`.
  * **Tables:** `employee_obligations`, `obligation_deductions`, `obligation_postponements`, with `decimal(12,2)`
    money columns.
  * **Controller and policy:** `Admin::EmployeeObligationsController`, `EmployeeObligationPolicy`.
  * **Services:** `Payroll::ObligationEditor`, `Payroll::ObligationInstallmentPostponer`,
    `Payroll::ObligationDeductor`.
  * **UI:** 5 admin views.
  * **None:** no API, no job.
* **Ownership:** Attendance & Payroll (`module-boundaries.md` §6).
* **Dependencies (verified against the branch, not assumed from the earlier audit):**
  * **Reads:** Organization & Access (`EmployeeScope`, users, branches) and Workforce (`BranchMembership`,
    `ShiftAssignment`), all in the allowed direction.
  * **Documented exceptions:** the `Business` / `User` inverse associations and the Workforce employee-page
    obligations card (SEC-M2-5).
  * **Writes:** no cross-domain writes.
  * **Cycles:** no cross-domain cycle. The obligations ↔ payroll-core coupling is **internal to Attendance &
    Payroll**: payroll calls the deductor, snapshot callbacks update the balance, and the obligation services call
    `EntryRecalculator`.
  * **Finance:** Finance reports read only the payroll column `PayrollEntry#obligations_deducted`.
* **Security found in M0:** SEC-M2-10, SEC-M2-11 and the SEC-M2-4 follow-up (§17.3).
* **Payroll defects found in M0:** AP-D4 and AP-D5 (§17.3).
* **Technical debt found in M0:** TD-AP9 to TD-AP12 (§10).
* **Baseline** (108 spec files at `869cadd`): 1,831 examples, 33 failures, 1 pending. All 33 IDs are in the
  documented baseline files (§17.5).

### 17.3 Security and correctness fixes (Milestone 2)

| ID | Fixed in | Before M1 of | What |
|---|---|---|---|
| SEC-M2-1 | `28b2100` | Pilot 1 | Biometric device administration requires `manage_devices` (§5.1) |
| SEC-M2-2 | `ca66c43` | Pilot 1 | Admin attendance-record changes use the attendance policy and data scope (§5.1) |
| SEC-M2-3 + SEC-M2-9 | `3d9127e` | Pilot 1 | Penalty-rule and shift administration authorize every action (§5.1) |
| SEC-M2-4 | `a384319` | Pilot 1 | An obligation's user and creator must belong to its business; payroll deducts only the period's business (§5.1) |
| **SEC-M2-10** | `869cadd` | **Pilot 2** | A `manage_obligations` holder can no longer pause, resume, cancel, edit (e.g. turn auto-deduct off) or postpone **their own** obligation; the owner is the only exception |
| **SEC-M2-11** | `869cadd` | **Pilot 2** | An unconfigured `manage_obligations` scope follows the hierarchy default (`EmployeeScope#relation` + own records), like the other payroll policies, instead of the whole business |
| **SEC-M2-4 follow-up** | `869cadd` | **Pilot 2** | Create, and reassignment on update, require the target employee to be in the actor's effective `manage_obligations` scope; the employee picker offers only those employees |
| **AP-D4** | `6177e8b` | **Pilot 2** | Pause / resume / cancel rebuild the employee's open payroll entries atomically with the status change (correctness, not security) |
| **AP-D5** | `b6d4526` | **Pilot 2** | Reassignment removes the obligation's open snapshots and rebuilds both employees' open entries, so there is no double deduction and no entry is created (correctness, not security) |

* **Documented behaviour change (SEC-M2-11):** a user whose `manage_obligations` scope is unset now reaches only
  their branch/area hierarchy. Business-wide obligation managers need the business scope configured explicitly.
* **Regression specs:**
  * `spec/requests/security/employee_obligations_authorization_spec.rb` (22);
  * `employee_obligations_business_scope_spec.rb` (9);
  * `spec/requests/payroll_obligation_lifecycle_spec.rb` (7);
  * `payroll_obligation_reassignment_spec.rb` (6).

### 17.4 M1, M6, M7

* **M1** (`c255f5e`): 24 characterization examples in `spec/characterization/attendance_payroll/`. **No new
  defect** — every probed behaviour was correct, and nothing broken was pinned.

  | File | Examples | Covers |
  |---|---|---|
  | `employee_obligation_lifecycle_spec.rb` | 9 | Transitions and refusals; atomic rebuild and rollback |
  | `employee_obligation_payroll_spec.rb` | 7 | Final installment and completion; reopen on recalculation; non-deductible states; no double deduction; finalized period untouched |
  | `employee_obligation_admin_spec.rb` | 8 | Create/edit derivations and 422s; show page; area and self scopes |

* **M6** (`9298ced`): `spec/architecture/attendance_payroll_obligation_boundary_spec.rb` (8).
  * **Guarded:** the 3 constants, their collections/tables and the 3 obligation services.
  * **Classified:** **20 references**:
    * **16 AP-internal:** the 3 models, the controller, 5 views, 3 services, and the payroll core that consumes
      obligation results (`PayrollPeriod`, `EntryCalculator`, `EntryRecalculator`, `PeriodGenerator`).
    * **4 documented exceptions:** the `Business` / `User` inverses, the Workforce employee-page card and the
      sidebar.
  * **Unexpected dependencies, cross-domain writes, circular dependencies:** none.
  * **No boundary object required.**
  * **Proof:** self-tests plus a planted probe (removed).
* **M7** (`77239ce`):
  * **Move:** `git mv` of the 3 models into `app/models/attendance_payroll/`. The renames are 100%, the blobs are
    unchanged and the old top-level files are gone.
  * **Unchanged:** the constants stay top-level and the tables are unchanged. There is no `AttendancePayroll`
    constant and no behaviour, database or API change.
  * **Folder:** reuses the existing collapse in `config/initializers/attendance_payroll_autoload.rb` from Pilot 1;
    no new initializer.
  * **Location spec:** `spec/architecture/attendance_payroll_obligation_model_location_spec.rb` (15) covers the
    location, constants, tables, associations, policy, scope and the deductor's snapshot class.
  * **Boundary spec:** only the model paths changed.
  * **Pattern validated:** the collapsed-folder pattern now holds for two AP groups (5 models).

### 17.5 Path decision and M8 verification

* **Why fast track (evidence-based):**
  * M0 found no cross-domain caller, write or cycle, so there was no need for a boundary or interface (M2) or
    caller routing (M3).
  * The services were already in the AP `Payroll::` namespace, so no M4.
  * M6 classified every reference and confirmed this.
  * **M5:** its condition was technically met (lifecycle rules in the controller, the duplicated count rule). The
    real need, though, is a service with audit, a reason and recalculation, which **changes behaviour**. It was
    therefore recorded as technical debt (TD-AP9 / TD-AP10), not done inside the migration. The behavioural part
    that affected money, the missing payroll rebuild, was fixed separately as AP-D4.
* **M8 final set:** 115 spec files — the 108-file M0 set, plus all architecture, characterization, security and
  API security specs, and the AP-D4/AP-D5 regression specs.

  Result: **1,891 examples, 33 failures, 1 pending.**

  | Group | Examples | Failures |
  |---|---|---|
  | Architecture | 69 | 0 |
  | Characterization (with API) | 353 | 0 (1 pending) |
  | Obligation characterization | 24 | 0 |
  | Obligation security | 31 | 0 |
  | AP-D4 / AP-D5 regression | 13 | 0 |
  | Security + API security | 239 | 0 |

* **Comparison by ID:** the 33 failing IDs are **identical** to the Pilot 2 M0 run and to the M7 run. None is
  new and none disappeared. All are **known baseline failures**:
  * `payroll_period_policy_spec:217`;
  * `api/v1/payroll_visibility_spec` ×9;
  * `api/v1/payroll_waive_scope_spec` ×17;
  * `payroll_review_approval_paths_spec` ×4 (all in `attendance-payroll-baseline-failures.txt`);
  * `sidebar_active_state_spec:215/293` (in `permission-role-baseline-failures.txt`).

  No flaky ID appeared.
* `zeitwerk:check` passes; RuboCop reports no offenses in the 16 Pilot 2 Ruby files; `git diff --check` is clean.
  The working tree is clean, and nothing in `db/`, routes or API controllers changed.

### 17.6 Candidate choice (M0)

Employee Obligations was selected over the other candidates as the only fast-track-eligible group whose security
issues were all fixed:

* **Penalty rules:** the Workforce `Shift` nested-attributes write needs an interface (standard path).
* **Salary configuration:** SEC-M2-5 / -6 / -7 and AP-D1 are open.
* **Payroll adjustments:** larger, bound to the payroll core, with a baseline failure in its own spec.
* **Advances, attendance records, payroll core:** cross-domain cycles or writes.

### 17.7 Remaining items after Pilot 2 (none fixed by this close-out)

| Item | Status | Notes |
|---|---|---|
| SEC-M2-1, -2, -3, -4, -9, -10, -11; SEC-M2-4 follow-up | **Fixed** | §5.1, §17.3 |
| AP-D4, AP-D5 | **Fixed** | §17.3 |
| SEC-M2-5 | **Deferred** (security, Medium) | Employee page shows salary and obligations without the AP policies. Needs Q-M2-5 |
| SEC-M2-6 | **Deferred** (security, Medium) | Salary-profile scope; self-salary changes. Needs Q-M2-4 |
| SEC-M2-7 | **Deferred** (security, Medium) | Advance and salary-profile scopes ignore the `view_payroll` scope |
| SEC-M2-8 | **Deferred** (security, Low–Medium) | Punch-log visibility, business-wide for the admin gate. Pinned in Pilot 1 M1 |
| SEC-M2-4 follow-up — obligation scope decision | **Resolved** by `869cadd` | Create and reassignment respect the effective scope (was a product decision) |
| SEC-M2-2 follow-up — attendance edit lookup | **Product decision** (open) | Admin and web attendance edits use the `view_attendance` scope for lookup and allow editing one's own record |
| AP-D3 | **Known defect** (pinned, not fixed) | A punch updates a soft-deleted attendance record |
| AP-D1 | **Known defect** (deferred with SEC-M2-6/-7) | API salary-profile index raises `NoMethodError` |
| AP-D2 | **Known baseline failure** | API line-item `waive?` (pinned in API characterization) |
| TD-AP9 | **Technical debt** | Obligation lifecycle in the controller: no service, audit or reason |
| TD-AP10 | **Technical debt** | Duplicated installment-count rule; create derivations in the controller |
| TD-AP11 | **Technical debt** | Float money arithmetic in the obligation model / controller / editor |
| TD-AP12 | **Technical debt** | Stored, callback-maintained `remaining_amount` balance |
| TD-AP1 – TD-AP8 | **Technical debt** | §10 |
| TD-OA1, TD-PERF1, TD-FIN1 | **Known flaky baseline failures** | Faker apostrophe names |
| MIG-1, MIG-2 | **Technical debt** (database phase) | Migration history defects; never part of a domain move |
| TD-ST1 | **Technical debt** | ShiftTemplate branch-requirement inconsistency (Workforce) |
| R-L4 | **Known defect** (out of scope) | `lib/tasks/attendance.rake` queries a non-existent `permission_roles.role` column |
| Baseline failures (52 AP + 7 permission-role) | **Known baseline failures** | Unchanged by Pilot 2 |

### 17.8 Next pilot

**Not selected and not started.** It needs a separate selection and review step.

* §6 and §17.6 list the remaining candidates.
* Any suggestion there is a **recommendation only**, not a selection.

## 18. Milestone 2 — Finance & Sales Expenses: M0 and preconditions

**Status:** **COMPLETE** (close-out §18.8). M0 done; the preconditions are fixed; M1 `98edd8e` (§18.6); M2
`4b94668`, M3 `d009f0d`, M4 `0ca2dc5` (§18.7); **M5 evaluated as not needed**; M6 `ddaceb1`, M7 `ee47554` and M8
(§18.8). No next pilot is selected.

* **Path (approved):** the **standard path**, M0 → preconditions → M1 → M2 → M3 → M4 → (M5 only if needed) → M6 →
  M7 → M8.
* **Model folder for M7:** `app/models/finance_sales/`.
* **Decided M2 approach:** an Attendance & Payroll-defined finalization-effect contract that Finance & Sales
  implements and registers. It is synchronous and runs inside the existing finalization transaction: no event bus,
  HTTP or asynchronous work.

### 18.1 M0 summary (audit at `40fcc5d`)

* **Scope and ownership:** Finance & Sales owns all 8 models:
  * `Expense`, `ExpenseAllocation`, `ExpenseCategory`, `ExpenseType`, `ExpenseTag`, `ExpenseTagging`,
    `RecurringExpense`, `RecurringExpenseAllocation`;
  * their 6 `finance/` controllers;
  * `Finance::{ExpenseApproval, ExpensePaymentRecorder, RecurringExpenseGenerator, AllocationCalculator}`;
  * 5 policies and `Finance::GenerateDueRecurringExpensesJob`.

  `Finance::NumberSequencer` and the settlement code are shared Finance & Sales services.
* **References:** 49 external files.

  | Class | Count | What |
  |---|---|---|
  | FS-internal | 22 | |
  | Reporting reads | 20 | |
  | Documented exceptions | 4 | OA inverses and the permission catalogue; the IP laundry cost report |
  | UI | 2 | |
  | Cross-domain write | **1** | `Payroll::InsuranceExpenseGenerator`, AP → FS, inside `Payroll::Approver`'s finalization transaction; it writes `expenses`, `expense_categories` (find-or-create) and `expense_allocations`, and uses `Finance::NumberSequencer` |
  | Unexpected | 0 | |

* **Cycle:** **F3 (AP ↔ FS)** is confirmed. No new cycle.
* **Database:** no schema change is needed. The stored class names (`audit_logs`, `financial_settlements`, Active
  Storage) keep the constant `Expense`.
* **Coverage gaps for M1:**
  * the insurance integration end-to-end;
  * category / type / tag administration and isolation;
  * the recurring-expense controller, `generate` action and scope;
  * list visibility by branch and owner scope, and cross-business 404;
  * per-business number sequencing;
  * payment failure and rollback paths.

### 18.2 Preconditions fixed before M1

| Item | Kind | Commit | Fix | Regression spec |
|---|---|---|---|---|
| **SEC-M2-12** | Security (cross-business reference) | `6b4d300` | An expense could be tagged with another business's `ExpenseTag` (the foreign tag name rendered; the other business could no longer delete its tag). `Finance::ExpensesController` now refuses any non-business tag id with 422 before assignment (nothing saved or attached); `ExpenseTagging` validates the tag's business as a backstop. No new permission | `spec/requests/security/expense_tags_business_scope_spec.rb` (7; 5 fail on the old code) |
| **FS-D1** | Money correctness | `f88e022` | Reopening a finalized payroll left the insurance Expense active, so re-finalizing kept the stale amount. `Payroll::Reopener` (finalized → branch_review_completed, in its transaction) now calls `Payroll::InsuranceExpenseGenerator.void_for`, which voids the active expense; re-finalizing creates a new expense from the latest payroll | `spec/services/payroll/insurance_expense_refresh_spec.rb` (9; 6 fail on the old code) |
| **TD-FIN2** | Flaky test (recorded) | — (this checkpoint) | Faker apostrophe name (§10) | — |
| **TD-FIN3** | Flaky test (recorded) | — (this checkpoint) | Browser-timing race after "add row" (§10) | — |

**FS-D1 decision: void plus status "cancelled".**

* Finance reports, the dashboard and the laundry cost report count expenses by `status = "approved"` and never
  check `voided_at`. Voiding alone would therefore have counted the old **and** the new expense.
* On reopen, the insurance expense therefore gets `voided_at`, `voided_by` and `void_reason`
  ("Payroll period reopened: <reason>", en + ar), **and** `status: "cancelled"`. All four are already in
  `Expense::SYSTEM_GENERATED_MUTABLE_ATTRIBUTES`; an `insurance_expense_voided` audit log is written.
* Kept unchanged: history (never edited or deleted), the generator's idempotency guard, the zero-total behaviour,
  single/split allocation, finalization rollback, and the paid → finalized reopen (no void).
* The AP → FS write stays in one place (`Payroll::InsuranceExpenseGenerator`) for the M2 contract.

### 18.3 Verification and baseline

* **Focused set after both fixes** (133 files: the Expenses M0 set, all payroll services and requests, the payroll
  period policy, and both regression specs; it includes all security, characterization and architecture specs):
  **1,745 examples, 8 failures, 1 pending**. All 8 are documented baseline IDs:
  * `expense_policy_spec:54`;
  * `payroll_period_policy_spec:217`;
  * `payroll_review_approval_paths_spec` ×4;
  * `sidebar_active_state_spec:215/293`.

  TD-FIN2 and TD-FIN3 passed in that run. **0 new failure IDs.**

  | Group | Examples | Failures |
  |---|---|---|
  | Architecture | 69 | 0 |
  | Security + API security | 246 | 0 |
  | Characterization | 353 | 0 (1 pending) |

* `zeitwerk:check` passes; RuboCop reports no offenses in the 6 changed Ruby files; `git diff --check` is clean.
* No schema, migration, route or API change. The only non-Ruby change in the fixes is one en/ar locale key.

### 18.4 Next

**M1 is ready to start, after approval.** Its scope is the gaps in §18.1, characterizing the behaviour **after**
SEC-M2-12 and FS-D1.

### 18.5 FS-D2 and the pre-M1 checkpoint

**FS-D2 (correctness, not security) is fixed in `94c4dce`.** It was found while probing for M1.

* **What was wrong:**
  * Expense category names are unique per business regardless of case, through a model validation and a unique
    index on `lower(name)`.
  * But `Payroll::InsuranceExpenseGenerator` looked "Social Insurance" up with a case-sensitive
    `find_or_create_by!`.
  * A business that already had, say, "social insurance" therefore could not finalize payroll: the create was
    rejected and `Payroll::Approver` rolled the finalization back.
* **The fix:** the lookup is case-insensitive and scoped to the period's business. An existing category is reused
  whatever its capitalisation; otherwise the canonical "Social Insurance" category is created. No schema change; no
  other category behaviour changed.
* **Regression spec:** `spec/services/payroll/insurance_expense_category_spec.rb` (6). The 3 capitalisation cases
  fail on the old code. The other 3 (canonical category reused, canonical created, another business's category
  never reused) pass both ways.

**Flaky tests recorded after review** (§10, `attendance-payroll-baseline-failures.txt`; specs unchanged):

* **TD-FIN3** now also covers `expense_duplicate_branch_spec.rb[1:1]`, the same "add row" race in the same loop.
* **TD-FIN4:** `expense_register_payment_spec.rb:27`, the "paid from balance" checkbox race before submit.

**Verification at `94c4dce`:**

* FS-D2 spec: 6/0.
* Focused Payroll/Finance set (the 133-file §18.3 set plus the FS-D2 spec): **1,751 examples, 9 failures,
  1 pending.**
  * 8 are the documented baseline IDs, unchanged: `expense_policy_spec:54`, `payroll_period_policy_spec:217`,
    `payroll_review_approval_paths_spec` ×4 and `sidebar_active_state_spec:215/293`.
  * 1 is TD-FIN2 (flaky).
  * **No unexplained failure IDs.**
* `zeitwerk:check` passes; RuboCop is clean; `git diff --check` is clean.
* No schema, migration, route or API change.

**Status:** all pre-M1 items are resolved (SEC-M2-12, FS-D1, FS-D2, TD-FIN2, TD-FIN3, TD-FIN4). **Expenses M1 is
ready and has not started.**

### 18.6 M1 characterization (complete)

**Status: COMPLETE**, commit `98edd8e` "test: characterize finance sales expenses".

* **Production code:** unchanged in this step. No database, schema, migration, route or API change; no model moved.
* **Not done:** no boundary spec and no initializer.

**New characterization: 40 examples in `spec/characterization/finance_sales/`.** The folder name organizes specs
only.

| File | Examples | What it pins |
|---|---|---|
| `insurance_expense_spec.rb` | 7 | The payroll Social Insurance expense: approved, system-generated, dated at period end, created/approved by the actor, `direct` and not linked to a balance, no settlements, an `insurance_expense_generated` audit. Edit/delete raise `ReadOnlyRecord`. Only insured entries count. An unassigned employee goes to the business's first branch. An existing (even inactive) category is reused. The business's `EXP-` sequence continues. Nothing is created on the paid transition |
| `expense_catalog_admin_spec.rb` | 11 | Categories/types/tags. `view_expenses` is view-only and `manage_*` creates; users without a finance permission are kept out. Names are case-insensitively unique per business, and the same name may exist in another business. A type under a foreign category → 422; a foreign category → 404. Deleting a category with expenses, or a tag in use, is refused. The types `options` JSON returns active types, ordered, as `id`/`name`, and is empty for a foreign category |
| `recurring_expenses_admin_spec.rb` | 9 | A branch-scoped create is attributed to the actor; an out-of-scope branch is refused; another branch → 404; invalid → 422. `generate` creates a pending, system-generated expense and advances the schedule. `view_expenses` alone is read-only (no update / generate / delete). A foreign template → 404. Deleting a template keeps the generated expenses, detached |
| `expense_visibility_spec.rb` | 7 | A branch manager lists only the managed branch; the owner sees the business but not another business; another branch / business show → 404. A draft can be submitted. An editor may change a pending but not an approved expense. Only drafts are deleted |
| `number_sequencer_spec.rb` | 4 | Per-business, per-kind prefixes (`EXP-` / `BRQ-`); continues after the highest prefixed number (other numbers ignored); independent businesses; an unknown kind → `KeyError` |
| `expense_report_consumers_spec.rb` | 2 | `ExpenseSummary` / `ExpenseTrend` count status `approved` only. The insurance expense counts while active, and only its replacement counts after reopen/re-finalize (FS-D1) |

**Intentionally reused (not duplicated):**

* the Expense model (13), policy (25) and approval service (22) specs;
* payments: request (17), recorder (13) and payment-type (14) specs;
* allocations (17 + 10), approve/reject (8) and cancel (4);
* the recurring generator (9) and job (4);
* the Finance system and report specs;
* the SEC-M2-12 (7), FS-D1 (9) and FS-D2 (6) regression specs.

**Findings:** no new security finding and no new defect. Every probed behaviour was correct; nothing broken was
pinned.

**Verification:**

* **New specs:** 40/0 in default order, with seeds 12345, 98765 and 2468, and file by file.
* **Focused Finance/Payroll set** (the 133-file §18.3 set, plus the FS-D2 spec and the new specs): **1,791 examples,
  8 failures, 1 pending.** Exactly the documented baseline IDs:
  * `expense_policy_spec.rb:54`;
  * `payroll_period_policy_spec.rb:217`;
  * `payroll_review_approval_paths_spec.rb:45/58/79/98`;
  * `sidebar_active_state_spec.rb:215/293`.

  **No new failure IDs.** The pre-M1 run (1,751 examples) had the same 8 IDs plus TD-FIN2.
* **TD-FIN2** (flaky) **passed** in this run, as a known flaky ID may. TD-FIN3 and TD-FIN4 also passed.

  | Group | Examples | Failures |
  |---|---|---|
  | Architecture | 69 | 0 |
  | Security + API security | 246 | 0 |
  | All characterization (with API) | 393 | 0 (1 pending) |

* `zeitwerk:check` passes; RuboCop is clean on the 6 new files; `git diff --check` is clean.

**Path decision after M1: the standard path is kept.**

M1 did not change the dependency evidence:

* `Payroll::InsuranceExpenseGenerator` still writes Finance & Sales data (`expenses`, `expense_categories`,
  `expense_allocations`) inside payroll finalization.
* Since FS-D1 it also voids the expense when payroll is reopened.
* Cycle F3 (AP ↔ FS) therefore remains.

M2–M5 remain required as approved in M0. The fast path (M1 → M6 → M7 → M8) was considered and **not** adopted,
because skipping them would leave a real cross-domain write unresolved. The next steps are:

* **M2:** an Attendance & Payroll-defined finalization/reopen-effect contract, implemented and registered by Finance
  & Sales. It is synchronous and runs inside the existing transactions.
* **M3:** route `Payroll::Approver` and `Payroll::Reopener` through it.
* **M4:** move the expense-building and void code into `Finance::`.
* **M5:** only if needed.
* Then **M6** (boundary spec), **M7** (`app/models/finance_sales/` plus initializer) and **M8**.

At this checkpoint M2–M8 had not started. M2–M4 are now complete (§18.7).

### 18.7 M2–M4: contract, routing and relocation (complete)

M2 and M3 were committed without a docs checkpoint, as instructed; they are recorded here with M4.

| Step | Commit | What |
|---|---|---|
| **M2** | `4b94668` | `Payroll::FinalizationEffects` (Attendance & Payroll contract: `OPERATIONS`, `register` checks every operation, `NotRegistered` instead of a silent skip). `Finance::PayrollFinalizationEffects` implements it, delegating to the then-existing generator; registered in `config/initializers/payroll_finalization_effects.rb` (`to_prepare`). Contract spec `spec/services/payroll/finalization_effects_spec.rb` |
| **M3** | `d009f0d` | `Payroll::Approver` (→ `finalized`) and `Payroll::Reopener` (`finalized` → `branch_review_completed`) call the contract, inside their existing transactions; the paid transition and paid → finalized reopen trigger nothing, as before. Routing spec `spec/services/payroll/finalization_effects_routing_spec.rb` |
| **M4** | `0ca2dc5` | The insurance-expense logic is relocated by owner and `Payroll::InsuranceExpenseGenerator` is removed (below) |

**M4 decision: split per `module-boundaries.md` §14.1 A** (approved before implementation). The generator mixed a
payroll read with Finance writes. Moving it whole into `Finance::` would have made Finance read payroll entries and
shift assignments, inverting the dependency instead of removing it. Instead:

* **Attendance & Payroll owns the employer insurance calculation:** `Payroll::EmployerInsuranceCost.for(period)`
  returns `total` and `by_branch` (`{branch_id => amount}`): insured entries only, attributed via the Workforce
  `ShiftAssignment.branch_ids_by_user` read, falling back to the business's first branch. Read-only.
* **Finance & Sales owns the expense:** `Finance::PayrollInsuranceExpense` creates it (idempotent while an active
  expense exists, nothing for a zero total), reuses the "Social Insurance" category case-insensitively (FS-D2),
  sets a single branch or a percentage split with exact amounts and rounding absorbed by the last row, numbers it
  via `Finance::NumberSequencer`, voids it on reopen (`voided_at` / `voided_by` / `void_reason` plus `status:
  "cancelled"`, FS-D1) and writes the `insurance_expense_generated` / `insurance_expense_voided` audits.
* **Final contract signature:**

  ```ruby
  Payroll::FinalizationEffects.period_finalized(period:, actor:,
                                                employer_insurance_total:, employer_insurance_by_branch:)
  Payroll::FinalizationEffects.period_reopened(period:, actor:, reason:)
  ```

  `Payroll::Approver` computes the cost inside its transaction just before the call.
  `Finance::PayrollFinalizationEffects` stays the registered adapter, forwarding to
  `Finance::PayrollInsuranceExpense.record(period:, actor:, total:, by_branch:)` / `.void_for(period:, actor:, reason:)`.
* **`Payroll::InsuranceExpenseGenerator` is removed,** with no compatibility wrapper: every reference was migrated.
  Only provenance comments name it (the two new services and their specs).
* **One recorded nuance:** the cost is now computed before Finance's idempotency check, so it also runs on a call
  that creates nothing. It is read-only; observable behaviour is unchanged.

**Cycle F3 (AP ↔ FS) is eliminated.**

* Attendance & Payroll code (`app/services/payroll`, `app/models/attendance_payroll`) has no non-comment reference
  to `Finance::`, `Expense*` or `NumberSequencer`; it reaches Finance only through its own contract and the
  boot-time registration.
* Finance's only reference to Attendance & Payroll is the period handed to it (id, `period_end`) and the
  `source_payroll_period` foreign key, an allowed FS → AP direction. Source-scan examples pin both sides: the
  contract is free of Finance references, and `Finance::PayrollInsuranceExpense` reads no payroll entries or shift
  assignments.
* No allow-list exception was added; no new cross-domain dependency was found.

**Specs:** new `spec/services/payroll/employer_insurance_cost_spec.rb` (4) and
`spec/services/finance/payroll_insurance_expense_spec.rb` (10). Updated for the new owner and payload, with
unchanged expectations: the contract, routing, FS-D1 refresh and `expense_details` specs; comment-only edits in the
`finance_sales` characterization and `branch_profitability` specs.

**Verification (each step compared with the previous one by exact failure ID):**

| Step | Focused Finance/Payroll set | Failures |
|---|---|---|
| M1 (§18.6) | 1,791 examples, 1 pending | 8 baseline IDs |
| M2 | 1,800 examples, 1 pending | the same 8 |
| M3 | 1,806 examples, 1 pending | the same 8 |
| M4 | 1,820 examples, 1 pending (+14 = the new specs) | the same 8: 0 new, 0 gone |

The 8 are the documented baseline IDs (`expense_policy_spec.rb:54`, `payroll_period_policy_spec.rb:217`,
`payroll_review_approval_paths_spec.rb:45/58/79/98`, `sidebar_active_state_spec.rb:215/293`). **No new failure
IDs**; no flaky ID was reclassified and the baseline files are unchanged.

At M4, architecture + characterization + API characterization + security + API security: **708 examples,
0 failures, 1 pending.** `zeitwerk:check` passes; RuboCop is clean on the 14 changed Ruby files; `git diff --check`
is clean.

**No database, schema, migration, route or API change** in M2–M4. No model moved. The locale key
`payroll.insurance_expense_void_reason` is unchanged.

**M5 evaluated as not needed.** M5 extracts operation services when business logic sits in controllers or in the
wrong layer. After M4 every piece of this workflow is already a service in its owning domain (the cost in
`Payroll::`, the expense in `Finance::`, the transitions in `Payroll::Approver` / `Reopener`), no controller holds
insurance or expense-generation logic, and the only cross-domain call goes through the contract. There is nothing
for M5 to move.

**Follow-up for M8:** `module-boundaries.md` §14.1 A still says "Today `Payroll::InsuranceExpenseGenerator` is called
inside `Payroll::Approver`"; it is outside this checkpoint's scope and should be updated with the final docs.

At this checkpoint M6 had not started; M6–M8 are recorded in §18.8.

### 18.8 M6–M8: boundary, physical move and close-out — Pilot 3 COMPLETE

**M6 — boundary enforcement (`ddaceb1`).** `spec/architecture/finance_sales_expense_boundary_spec.rb` (20 examples),
built on the post-M4 dependency graph (1,113 `app/` + `lib/` files scanned; 59 with guarded references; 149
Attendance & Payroll files with **0** Finance references).

* **Expenses group:** the 8 models, their Finance services and job, `.expenses`-style collections, association
  macros and the `expense_*` tables may be used only by:
  * **Finance & Sales:** `app/{controllers,services,views,jobs}/finance/`, the 8 models, `custody_transaction.rb`,
    `financial_settlement.rb`, `pos_import.rb`, `expense_policy.rb`, `recurring_expense_policy.rb`;
  * **Reporting (read-only, `module-boundaries.md` §9):** `app/services/finance/dashboard/`,
    `app/views/finance/dashboard/`, `finance/dashboard_controller.rb`, `finance/dashboard_filters.rb`,
    `finance/reports/expense_sources.rb`;
  * **4 exceptions:** `Business` and `Branch` (Organization & Access inverses), `workspace_helper.rb` (Finance
    workspace nav, `policy(Expense …)`), `Laundry::LaundryCostSummaryReport` (IP read of approved expenses;
    read-only, target Reporting).

  Reporting and the laundry report are checked for writes. The allow-list and directories must each still be needed
  (this removed `app/policies/finance/`). The M0 permission-catalogue exception is no longer needed: permission
  names, route helpers, `t(...)` keys and `expenses:` metric keys are not guarded.
* **Payroll insurance path:** Attendance & Payroll names no `Finance::`, expense internal or `NumberSequencer`; the
  Approver / Reopener go through `Payroll::FinalizationEffects`; only `config/initializers/
  payroll_finalization_effects.rb` names `Finance::PayrollFinalizationEffects`, which is the registered handler;
  the Finance side reads no payroll entries, line items or shift assignments; `Payroll::EmployerInsuranceCost`
  keeps the calculation and only AP code calls it; `Expense#source_payroll_period` (FS → AP) stays valid.
* **Probes:** forbidden references planted on disk (a Payroll service calling `Finance::PayrollInsuranceExpense` and
  `Finance::NumberSequencer`; a `ShiftAssignment` read in the Finance service; an Inventory service using
  `expense_categories`; a write under `finance/dashboard/`; another domain naming the contract implementation) each
  failed the spec and were removed. The dashboard-write probe first passed — the read-only check covered only
  listed files — and the check was fixed to cover the Reporting directories before the commit.

**M7 — physical move (`ee47554`).** The 8 Expenses models (`Expense`, `ExpenseAllocation`, `ExpenseCategory`,
`ExpenseType`, `ExpenseTag`, `ExpenseTagging`, `RecurringExpense`, `RecurringExpenseAllocation`) moved with `git mv`
from `app/models/` to `app/models/finance_sales/`: recorded as renames, SHA-256 identical. Only these 8 (the M0
scope, all associated with each other); the custody, settlement, POS, reconciliation and sales models stay.

* **Initializer (approved before creation):** `config/initializers/finance_sales_autoload.rb`, a one-line collapse
  like the other three domains. No `FinanceSales` namespace; constants stay top-level; tables and stored type names
  (`polymorphic_name`) unchanged.
* **`spec/architecture/finance_sales_expense_model_location_spec.rb`** (34 examples): location, no top-level file,
  table and type name, no namespace, 32 named associations resolve the same classes, and a sweep of every
  non-polymorphic association in the app.
* The M6 allow-list only followed the 8 new paths.

**M8 — final verification (on `ee47554`).**

| Run | Result |
|---|---|
| Final Pilot 3 set (the §18.3 133-file set + all architecture, characterization, API characterization, security and API security + FS-D1/FS-D2 regressions + contract, routing, M4 and both FS architecture specs) | **1,874 examples, 8 failures, 1 pending** |
| Architecture | 123 examples, 0 failures |
| Security + API security | 246 examples, 0 failures |
| Characterization + API characterization | 393 examples, 0 failures, 1 pending |
| `spec/characterization/finance_sales` | 40 examples, 0 failures |

* **Failures:** exactly the 8 deterministic baseline IDs — `expense_policy_spec.rb:54`,
  `payroll_period_policy_spec.rb:217`, `payroll_review_approval_paths_spec.rb:45/58/79/98`,
  `sidebar_active_state_spec.rb:215/293`. **No new failure IDs.**
* **Comparison by step:** M1 1,791 / M2 1,800 / M3 1,806 / M4 1,820 / M6 1,840 / M7 1,874 / M8 1,874 examples; the
  same 8 IDs every time. In the M6 and M7 runs `permission_roles_spec.rb:28` also failed: the documented flaky
  **TD-OA1** (Faker "Member O'Connell" / "Unassigned O'Hara"; 8/8 and 6/6 isolated passes); it passed at M8.
* **Documented flaky IDs (unchanged):** TD-OA1, TD-FIN1, TD-FIN2, TD-FIN3 (`[1:1]`, `[1:2]`), TD-FIN4, TD-PERF1.
  `attendance-payroll-baseline-failures.txt` is unchanged.
* `zeitwerk:check` passes; RuboCop clean on the 35 Ruby files changed since M0 (`40fcc5d`); `git diff --check`
  clean.

**Confirmed at close-out:**

* No database, schema or migration change; no route or API change. Since M0 the only `config/` changes are the two
  approved initializers and the FS-D1 void-reason locale key (en + ar).
* Production behaviour changed only through the separately approved `fix:` commits (SEC-M2-12, FS-D1, FS-D2); M2–M4
  preserved behaviour (same failure IDs, unchanged expectations); M7 is a byte-identical move.
* No new cross-domain dependency and no new boundary exception beyond the four classified in M6; cycle F3 is
  eliminated.
* No `FinanceSales` namespace; the 8 models are top-level constants; the Organization & Access, Workforce and
  Attendance & Payroll collapse initializers are unchanged and their location specs pass.

**Pilot 3 summary.**

* **Preconditions:** SEC-M2-12 (`6b4d300`, cross-business expense tags); FS-D1 (`f88e022`, reopen voids and cancels
  the insurance expense); FS-D2 (`94c4dce`, case-insensitive "Social Insurance" category).
* **Dependency inversion (M2 → M4):** the AP → FS write became an AP-defined, FS-implemented contract (M2), the
  callers were routed through it (M3), and the logic was split by data ownership (M4): Payroll computes the employer
  insurance cost, Finance owns the expense. `Payroll::InsuranceExpenseGenerator` is gone.
* **M5 not needed:** after M4 every part is a service in its owning domain and no controller holds the logic.

**Technical debt from this pilot:**

* **FS-D3 (open, §10):** the POS fee category lookup is case-sensitive — the FS-D2 defect in
  `Finance::PosImports::ExpenseGenerator`; it can block POS imports. Found in M8 by searching for the fixed pattern;
  recorded, not fixed (approved).
* **TD-FIN2, TD-FIN3, TD-FIN4:** flaky specs recorded during the pilot (§10).
* **Docs follow-up:** `module-boundaries.md` §14.1 A still describes `Payroll::InsuranceExpenseGenerator` as today's
  behaviour; it was outside this close-out's scope.
* **Accepted nuance (not debt):** `Payroll::EmployerInsuranceCost` runs before Finance's idempotency check, so it
  also runs on a call that creates nothing; it is read-only.

**Pilot 3 (Finance & Sales Expenses) is COMPLETE.** Nothing was pushed or merged; `main` stays at `c054fa3`. No next
pilot is selected.

### 18.9 Milestone 2 final gate — full suite vs `main` (READY FOR PR)

Run after the milestone review, as its recommended next action. Same seed (20261006) on both sides; `main` was run
in a temporary scratch worktree (removed afterwards). No code, spec or schema was changed for the gate.

| | Branch @ `9952d68` | `main` @ `c054fa3` |
|---|---|---|
| Spec files | 561 | 527 |
| Examples | 7,818 | 7,459 |
| Failures | 95 | 95 |
| Pending | 1 | 1 |
| Errors outside examples | none | none |

The branch's extra 34 files / 359 examples are Milestone 2's new characterization, regression and architecture
specs.

**Comparison by exact failure ID:**

* **94 of 95 failing IDs are identical on the branch and `main`:**
  * **86** are in the documented baseline files (`permission-role-`, `department-job-title-` and
    `attendance-payroll-baseline-failures.txt`);
  * **8** are in no baseline file but fail on `main` too, so they pre-date the milestone; the older baseline files
    were recorded at earlier commits or over narrower sets. They are not added to the baseline files:
    `spec/services/inventory/imports/stock_issue_importer_spec.rb:143`,
    `spec/system/finance/expense_amount_distribution_spec.rb:28`,
    `spec/system/inventory/purchase_request_form_spec.rb:94`, `:116`, `:141`, `:160`, `[1:1]`, `[1:2]`.
* **1 `main`-only ID:** `spec/system/finance/expense_register_payment_spec.rb:27`, the documented flaky **TD-FIN4**
  (it passed on the branch).
* **1 branch-only ID:** `spec/system/finance/deposit_responsibility_transfer_spec.rb:208`, recorded after review as
  the flaky **TD-FIN5** (§10): a browser assertion right after a page action; 6/6 isolated and 3/3 whole-file
  passes; Milestone 2 changed no related code, view, JavaScript, helper or layout. Not a milestone regression.
* No expected change from a completed pilot appears among the failures, and no ID differs in Attendance & Payroll,
  Organization & Access, Workforce, or API characterization / security.

**Result: no genuinely new failure.** **Milestone 2 (security hardening, Pilots 1–3) is READY FOR PR.** The PR is not
created; nothing is pushed or merged; `main` stays at `c054fa3`. No next pilot is selected.

## 19. Pilot 4 — Attendance & Payroll Penalty Rules: M0

**Status:** **COMPLETE** (close-out §19.12). M0 at `b28110f` (recorded in `b73fc34`); M1–M4 and M6 (§19.11); M5
not needed; M7 and M8 (§19.12). All on `feature/pilot-4-penalty-rules`, not pushed or merged.

### 19.1 Scope and ownership

* **Scope:** `PenaltyRule` (table `penalty_rules`) and its editing surfaces: `Admin::PenaltyRulesController`
  (+ `admin/penalty_rules/*`), `Api::V1::PenaltyRulesController`, `PenaltyRulePolicy`, and the penalty-rule rows of the
  Workforce `Shift` form (`penalty_rules_attributes`, `admin/shifts/_form`, `penalty_rules_controller.js`).
* **Ownership (confirmed, `module-boundaries.md` §6 / §10.1):**

  | Data / effect | Owner today | Notes |
  |---|---|---|
  | Penalty rules (configuration) | **AP** | Attached to a WF `Shift` by FK; no `business_id` — isolation is through the shift |
  | Penalty instances | **AP** — there is no penalty table | Penalties are computed, never stored as their own record |
  | Attendance effect | **AP** | `Attendance::TimeCalculator` uses the lowest rule threshold to flag Late / Early Departure on the record |
  | Payroll effect | **AP** | `Payroll::EntryCalculator` → `Attendance::PenaltyCalculator` → `late_penalty` / `early_leave_penalty` `PayrollLineItem`s |

* **Rules are evaluated live**, not snapshotted: a rule change has no immediate effect; it applies at the next
  attendance recompute or payroll generation / recalculation of an open period. Finalized and paid payroll is not
  rewritten (its line items are already stored).

### 19.2 Model and table

`app/models/penalty_rule.rb` (44 lines): `belongs_to :shift`; enums `rule_type` (`late_arrival`, `early_leave`) and
`deduction_type` (`fixed_amount`, `percentage_of_daily`); validations (presence; `threshold_minutes` > 0 and unique per
shift + rule type; `deduction_value` > 0 and ≤ 100 when a percentage; late-arrival rules rejected on hour-based
shifts); scopes `for_late_arrival`, `for_early_leave`, `ordered_by_threshold`; class methods `applicable_for`
(highest threshold reached) and `lowest_threshold`. No callbacks. Table `penalty_rules`: FK to `shifts`, unique index
(`shift_id`, `rule_type`, `threshold_minutes`).

### 19.3 Controllers, routes, policies, permissions

| Surface | Authorization | Notes |
|---|---|---|
| `Admin::PenaltyRulesController` new/create/edit/update/destroy (`/admin/shifts/:shift_id/penalty_rules`) | `PenaltyRulePolicy` → `manage_shifts` (SEC-M2-3) | Shift found in `current_user.business`; rule through the shift. Direct model writes, no service, **no audit log** |
| `Api::V1::PenaltyRulesController` index/create/update/destroy (`/api/v1/shifts/:shift_id/penalty_rules`) | `ShiftPolicy`: index `show?` (`view_shifts` / `manage_shifts` / `assign_shifts` / assigned to the shift); writes `update?` → `manage_shifts` | Legacy contract, raw model attributes. Direct writes, no service, **no audit log** |
| `Admin::ShiftsController` create/update (WF) with `penalty_rules_attributes` | `ShiftPolicy` → `manage_shifts` (SEC-M2-9) | **WF → AP write** (nested attributes) |
| `Shift has_many :penalty_rules, dependent: :destroy` (WF) | — | **WF → AP write** on shift deletion (only for shifts without assignments: `shift_assignments` is `restrict_with_error`) |
| Reads: `Admin::ShiftsController#show`, `ShiftsController#show` (employee shift page), `Api::V1::ShiftsController#show` (`penalty_rules` raw) | `ShiftPolicy` | WF pages and API composing AP data |

`manage_shifts` is a **business-wide, non-scopable** permission (`PermissionRole`, "global operations"), consistent with
business-wide shifts.

### 19.4 Consumers and reference classification

Code references to `PenaltyRule` / `penalty_rules` / `Attendance::PenaltyCalculator` in `app/` (26 code files,
excluding locales, routes, comments and CSS-class reuse in `shift_templates/_form`, `criteria_fields_controller.js`,
`application.css`):

| Class | Files | Classification |
|---|---|---|
| AP internal | `penalty_rule.rb`, `penalty_rule_policy.rb`, `admin/penalty_rules_controller.rb` + 3 views, `api/v1/penalty_rules_controller.rb`, `attendance/{penalty_calculator, time_calculator, record_recomputer, status_backfill}.rb`, `payroll/{entry_calculator, permission_applier, punch_correction_applier}.rb` | Internal |
| WF → AP inverse association | `shift.rb` `has_many :penalty_rules` (AP reads go `record.shift_assignment.shift.penalty_rules`) | **Documented exception** (M0 class C) |
| WF → AP **write** | `shift.rb` `accepts_nested_attributes_for` + `dependent: :destroy`; `admin/shifts_controller.rb` (`penalty_rules_attributes`); `admin/shifts/_form.html.erb`, `shift_form_controller.js`, `penalty_rules_controller.js` | **Cross-domain write**, `module-boundaries.md` §14.2 #9 (M0 E #4) — the pilot's target |
| WF reads / UI composition | `admin/shifts/show.html.erb` (lists rules, links to AP admin), `shifts_controller.rb` + `shifts/show.html.erb`, `api/v1/shifts_controller.rb` (`penalty_rules` in show) | Valid read (UI / API composition) |
| WF → AP via employee requests | `requests/canceller.rb` (calls `PenaltyCalculator`, restores penalty line items), `requests/punch_correction_applier.rb` (preloads rules) | **Documented cross-domain writes** §14.2 #3 / #4 (WF ↔ AP request cycle) — outside this pilot |
| OA → AP read | `admin/branches_controller.rb` + `admin/branches/_shifts.html.erb` (preload and rule count in the branch staff view) | **Unexpected (read-only)**: not listed explicitly; it rides on the documented OA → WF branch-staff-view violation (§12.2). Classify in M6 |
| UI shell | `workspace_helper.rb` (nav entries) | Documented infrastructure |
| FS, IP, Reporting | none | — |

### 19.5 Dependency graph (before)

```
Workforce                          Attendance & Payroll
─────────                          ────────────────────
Shift ──has_many / nested write / dependent destroy──▶ PenaltyRule ──belongs_to──▶ Shift
  ▲  Admin::ShiftsController (form rows) ──writes──▶ penalty_rules
  │
Requests::Canceller / PunchCorrectionApplier ──▶ Attendance::PenaltyCalculator, payroll_line_items (§14.2 #3/#4)

PenaltyRule
   ↓  (thresholds)                  ↓  (amounts)
Attendance::TimeCalculator     Attendance::PenaltyCalculator
   ↓  Late / Early flags            ↓
AttendanceRecord              Payroll::EntryCalculator, Payroll::PermissionApplier
                                    ↓
                              PayrollLineItem (late_penalty / early_leave_penalty)

Organization & Access: admin/branches staff view ──reads──▶ shift.penalty_rules.size
```

**Circular dependency:** at model level `PenaltyRule → Shift` (AP → WF, allowed) and `Shift → PenaltyRule` (WF → AP:
inverse association, nested write, cascade destroy) form a WF ↔ AP cycle. The write half is what the pilot must
invert; the request-services half belongs to the separate WF ↔ AP request cycle (F1 / F2).

### 19.6 Security review — no new finding

Throwaway request probes (run from a scratch file, removed; 14 / 14 as expected):

* API create / update / destroy with `view_shifts` only → 403, nothing changed; an employee assigned to the shift → 403
  on create.
* API rule of another business through an own shift, or on a foreign shift → 404; a rule of another own shift through
  the wrong shift → 404; `shift_id` is not mass-assignable.
* API index: an assigned employee may read the rules of their shift (matches the web employee shift page); an
  unassigned employee → 403.
* Web `PATCH /admin/shifts/:id` with `penalty_rules_attributes` naming another business's rule, or another shift's rule
  → 404, unchanged.
* A late-arrival rule on an hour-based shift via API → 422.

Business isolation holds through the shift (no `business_id` on the table); there is no branch dimension (shifts and
`manage_shifts` are business-wide). Penalty rules reveal deduction policy, not individual pay. SEC-M2-3 and SEC-M2-9
(fixed in `3d9127e`) cover every web write path; the API paths were already authorized.

### 19.7 Characterization coverage

| Area | Existing coverage |
|---|---|
| Model rules | `penalty_rule_spec` (14), `shift_spec` (31; one penalty example) |
| Calculation / thresholds | `penalty_calculator_spec` (10), `time_calculator_spec` (35) |
| Payroll impact | `entry_calculator_spec` (34 penalty mentions), `permission_applier_spec` (12), `regenerator_penalty_waiver_spec`, `line_item_reviewer_spec`, scenario `multi_branch_payroll_cycle` |
| Requests (WF) | `requests/canceller_spec` (12) |
| Web CRUD, permissions, isolation | `security/admin_shifts_and_penalty_rules_authorization_spec` (26), incl. nested shift-form writes |
| API | `api/v1/characterization/management_spec`: shift show with `penalty_rules`, rules index, foreign-shift 404 |

**Gaps for M1 (not filled in M0):**

1. API penalty-rule **writes**: create / update / destroy success shapes, validation-error shape, `view_shifts` → 403,
   cross-business and cross-shift 404, assigned-employee index visibility (all probed above, none pinned).
2. Web nested `penalty_rules_attributes` with another shift's / business's rule id → 404 (probed, not pinned).
3. `Shift` deletion cascading its rules, and a shift with assignments refusing deletion (rules kept).
4. Live evaluation: a rule edited / deleted after attendance changes the open period's penalty on the next
   recalculation and leaves finalized line items untouched.
5. The absence of an audit log on rule create / update / delete (pin current behaviour, labelled TD-P4-1).

### 19.8 Baseline (seed 20261006)

78-file set, recorded with its reproducible command in `attendance-payroll-penalty-rules-baseline-failures.txt`: **1,754 examples,
26 failures, 1 pending.** All 26 IDs are in a documented baseline file and fail on `main` @ `c054fa3` too (17
`payroll_waive_scope_spec` — AP-D2 family; 4 `check_in_service_spec`; 3 `permission_matrix_verification_spec`;
`shift_assignment_spec:7`; `shift_templates_spec:204`). **No new failure IDs; no penalty-rule spec fails.**

### 19.9 Technical debt found (recorded, not fixed)

| ID | Item |
|---|---|
| TD-P4-1 | Penalty-rule create / update / delete (web, API and shift-form nested rows) write **no audit log**, although rules drive payroll deductions (audit-first rule; same class as TD-AP2). A behaviour change: its own approved `fix:` |
| TD-P4-2 | `Attendance::PenaltyCalculator` uses `Float` for money (`daily_salary.to_f`, `deduction_value.to_f`, `round(2)`) — the TD-AP11 class |
| TD-P4-3 | Rules are not effective-dated: an edit applies retroactively to every open period on the next recalculation, and `TimeCalculator` flags already stored on records go stale until a recompute. Product decision needed before any change |
| TD-P4-4 | `Admin::PenaltyRulesController` and `Api::V1::PenaltyRulesController` write the model directly (no service); the API returns raw model attributes (legacy contract) |

### 19.10 Recommendation check and migration path

The approved P-4 assumptions hold:

* Penalty rules are an Attendance & Payroll candidate (ownership confirmed, all consumers AP except the WF / OA
  surfaces above).
* No unresolved security issue blocks the pilot (SEC-M2-3 / -9 fixed; probes clean).
* No pending product decision blocks it (TD-P4-3 is a future product question, not a pilot precondition).
* The surface is right for the **standard path**: there is a real cross-domain write (WF `Shift` nested attributes and
  cascade destroy into `penalty_rules`), so M1 → M6 → M7 → M8 alone would leave §14.2 #9 unresolved.

**Recommended path:** M1 → M2 → M3 → M4 → (M5 only if needed) → M6 → M7 → M8.

* **M2:** an AP-owned interface for penalty-rule changes that the WF shift form uses — with identical form behaviour
  (one transaction with the shift save, same validation errors and re-render). The design choice (an AP service
  called by `Admin::ShiftsController` vs keeping `accepts_nested_attributes_for` behind an AP contract) and the
  handling of `dependent: :destroy` are decisions for M2 approval.
* **M3:** route `Admin::ShiftsController` through it. **M4:** remove the WF-side write mechanics; the inverse
  `has_many` stays a documented exception (as OA inverses do).
* **M5:** decide on evidence after M4 (TD-P4-4 could be served by the M2 interface).
* **Out of scope:** the employee-request consumers (WF ↔ AP request cycle) stay documented exceptions.

**M1 readiness (at M0):** ready to start once approved; it should fill gaps 1–5 (§19.7). M1–M6 are recorded in
§19.11.

### 19.11 M1–M6: characterization, contract, routing, relocation and boundary

| Step | Commit | What |
|---|---|---|
| **M1** | `3efb46b` | 33 characterization examples in `spec/characterization/attendance_payroll/` for gaps 1–5: API writes (17), shift-form nested writes, cascade delete, P4-D1 and no-audit (11), live evaluation (5) |
| **M2** | `40e5ed0` | `Shifts::PenaltyRuleSettings` (Workforce contract, `assign(shift:, rows:)`), `Attendance::ShiftPenaltyRules` (AP implementation, delegating to nested attributes), `config/initializers/shift_penalty_rule_settings.rb` |
| **M3** | `4d7ae92` | `Admin::ShiftsController` stages the permitted rule rows (plain hashes, submitted order) only through the contract; same call order and transaction |
| **M4** | `a2ae7aa` | Row staging moved into `Attendance::ShiftPenaltyRules`; `Shift` drops `accepts_nested_attributes_for` and declares `autosave: true`; the form uses `fields_for :penalty_rules_attributes, …, index:` — markup byte-identical (edit, new, both 422 re-renders) |
| **M5** | — | **Not needed** (decision review after M4): no business rule sits in a controller or view or exists twice; the AP rule controllers do plain persistence (TD-P4-4), and the value a service would add — audit (TD-P4-1) — is a behaviour change for its own `fix:` |
| **M6** | `3fd9ba2` | `spec/architecture/attendance_payroll_penalty_rule_boundary_spec.rb` (18 examples) |

**Decision at M2 (approved): the contract is Workforce-defined and AP-implemented.** The brief asked for an AP-owned
interface called by Workforce, but Workforce is upstream of AP (`module-boundaries.md` §12.1; §18 rule 5): a WF → AP
call would have kept the cycle as a service call. As with Pilot 3's `Payroll::FinalizationEffects`, the upstream
domain defines the need and the downstream domain implements it, wired at boot so neither names the other.
Authorization stays with the caller (`ShiftPolicy`, `manage_shifts`); isolation does not depend on it (an id outside
the shift raises `RecordNotFound` → 404).

**P4-D1 (known defect, pinned in M1, not fixed):** `Admin::ShiftsController#destroy` ignores the result of
`@shift.destroy`; a shift with assignments is kept (`restrict_with_error`) but the redirect says "shift removed". No
data harm. Needs its own approved `fix:`.

**M6 — reference classification** (1,115 `app/` + `lib/` files; 52 code lines in 25 files):

| Class | Files |
|---|---|
| AP internal (11 + `app/views/admin/penalty_rules/`) | `penalty_rule.rb`; admin and API penalty-rule controllers; `attendance/{penalty_calculator, time_calculator, record_recomputer, status_backfill, shift_penalty_rules}.rb`; `payroll/{entry_calculator, permission_applier, punch_correction_applier}.rb` |
| WF lifecycle association | `shift.rb`: exactly `has_many :penalty_rules, dependent: :destroy, autosave: true` — rules live and die with their shift (the M0 `dependent: :destroy` question: kept as a classified lifecycle exception; a shift with assignments cannot be deleted); autosave persists the contract-staged rows in the shift's save; no nested attributes |
| Read-only display (UI / API composition) | WF shift form (`admin/shifts/_form`: staged rows and `PenaltyRule::RULE_TYPES` / `DEDUCTION_TYPES`), admin shift page (controller `#show` + view), employee shift page (`ShiftsController` + view), API shift show |
| OA branch staff view | `admin/branches_controller.rb` (`shift: :penalty_rules` preload) and `admin/branches/_shifts.html.erb` (`.shift.penalty_rules.size`) — see below |
| Documented request exceptions (§14.2 #3 / #4) | `requests/canceller.rb` (`Attendance::PenaltyCalculator`), `requests/punch_correction_applier.rb` (preload) — read-only on rules |
| UI shell | `workspace_helper.rb` (navigation lists `admin/penalty_rules`) |
| Composition root | `config/initializers/shift_penalty_rule_settings.rb` |

**Branch staff rule count — decision: an explicit, read-only exception.** The OA branch staff view reads the WF
shift assignments (the documented OA → WF branch-staff-view exception, `module-boundaries.md` §12.2) and, through the
shift, counts its rules. It writes nothing and adds no new dependency path; it is resolved together with that OA →
WF exception, not in this pilot. The spec allows it exactly two shapes — the preload and `.size` — so it cannot grow
silently.

**What the spec enforces:**

* Penalty-rule internals (`PenaltyRule`, `penalty_rules`, `PenaltyCalculator`, `ShiftPenaltyRules`) only in AP files
  and the classified exceptions; tight allow-list and directory checks.
* Read, request and UI-shell exceptions write no penalty rule; the branch staff view keeps its two read shapes; `Shift`
  keeps exactly the lifecycle association (and no nested attributes).
* Workforce code (shift, assignment, template, rule-profile, request and other WF globs): no `ShiftPenaltyRules`, no
  `PenaltyRule` beyond its two option lists, no nested-attributes mechanism and no penalty-rule writes; the shift
  controller stages through the contract; the contract names nothing from AP; only the composition root and AP name
  the implementation, which is the registered handler.

**Planted probes** (real files, then removed / reverted): a Workforce service calling `PenaltyRule.create!` and
`Attendance::ShiftPenaltyRules`; an Inventory service counting `shift.penalty_rules`; `destroy_all` added to the
employee shift page; a widened read (`each`) in the branch staff view; `accepts_nested_attributes_for` re-added to
`Shift`. Six rules failed as expected; the spec is green again with the probes removed.

**Verification (seed 20261006):**

| Run | Result |
|---|---|
| Pilot 4 specs (M1–M4 + M6) | 84 examples, 0 failures (M1–M4 also with seeds 12345 / 98765) |
| Focused Pilot 4 set + Pilot 4 specs | 1,838 examples, **26 failures**, 1 pending — exactly the IDs in `attendance-payroll-penalty-rules-baseline-failures.txt`; none new, none gone |
| Architecture | 141 examples, 0 failures |
| Security + API security | 246 examples, 0 failures |
| Characterization + API characterization | 426 examples, 0 failures, 1 pending |

`zeitwerk:check` passes; RuboCop and `git diff --check` clean. No production code, schema, route or API change in
M6.

**Open for M8:** the header comment of `spec/services/shifts/penalty_rule_settings_spec.rb` still describes the M2
delegating implementation (comment only). Technical debt TD-P4-1 – TD-P4-4 and P4-D1 unchanged.

### 19.12 M7–M8: physical move and close-out — Pilot 4 COMPLETE

**M7 — physical move (`a3b6463`).** Decided by a readiness review after M6 (M7 is optional; the reason was not
"the pattern has an M7"): `PenaltyRule` was the only pilot-completed AP model outside the domain folder, the folder
and its collapse already existed, and nothing depends on the file path except one allow-list entry.

* `git mv app/models/penalty_rule.rb app/models/attendance_payroll/penalty_rule.rb` — recorded as a rename, SHA-256
  identical. The existing `attendance_payroll_autoload.rb` collapse covers it; no new initializer.
* The constant stays top-level `PenaltyRule` (no `AttendancePayroll::PenaltyRule`); the table stays `penalty_rules`;
  no migration names the model (`20260507000008_create_penalty_rules.rb` names only its migration class); no stored
  type names (no attachments, audit or polymorphic rows); the factory is unaffected.
* The M6 boundary allow-list only follows the new path.
* `spec/architecture/attendance_payroll_penalty_rule_model_location_spec.rb` (6 examples): location, no top-level
  file, table, no namespace, `PenaltyRule#shift` ↔ `Shift#penalty_rules` resolve the same classes, and the
  association options are exactly `dependent: :destroy, autosave: true`.

**M5 — not needed (decision review after M4).** Evidence: no business rule sits in a controller or view or exists
twice (rules are model validations; the shift form's JavaScript only mirrors the hour-based rule-type hint); the AP
penalty-rule controllers do plain persistence (TD-P4-4), inside AP, so a service would not move any boundary; the value
a service would add — audit (TD-P4-1) — is a behaviour change for its own `fix:` (the Pilot 2 rule). M6 classified
everything that remained.

**M8 — final verification (on `a3b6463`, seed 20261006).**

| Run | Result |
|---|---|
| Pilot 4 specs (M1–M4, M6, M7: 9 files) | **90 examples, 0 failures** |
| Focused Pilot 4 set (78 files) + Pilot 4 specs | **1,844 examples, 26 failures, 1 pending** |
| Architecture | 147 examples, 0 failures |
| Security + API security | 246 examples, 0 failures |
| Characterization + API characterization | 426 examples, 0 failures, 1 pending |

* **Failures:** exactly the 26 IDs in `attendance-payroll-penalty-rules-baseline-failures.txt` — none new, none gone
  (17 `payroll_waive_scope_spec`, 4 `check_in_service_spec`, 3 `permission_matrix_verification_spec`,
  `shift_assignment_spec:7`, `shift_templates_spec:204`; all also fail on `main` @ `c054fa3`). The same 26 at every
  step: M0 1,754 / M1 1,787 / M2 1,798 / M3 1,808 / M4 1,820 / M6 1,838 / M7–M8 1,844 examples. No flaky ID appeared.
* `zeitwerk:check` passes; RuboCop clean on the 15 Ruby files changed since `b28110f`; `git diff --check` clean.

**Confirmed at close-out:**

* No database, schema, migration, route or API change since `b28110f`; the only `config/` change is the approved
  composition root `config/initializers/shift_penalty_rule_settings.rb`.
* Production behaviour unchanged: M1 pinned it, M2–M4 kept every M1 example and the form markup (byte-identical
  edit / new / 422 HTML) unchanged, M7 is a byte-identical move. P4-D1 stays pinned and unfixed.
* No security regression (security suites green; isolation pinned by M1 and the contract specs) and no unexpected
  cross-domain dependency: every reference is classified in §19.11 and enforced by the M6 spec; the branch staff
  rule count is an explicit read-only exception limited to its two read shapes.

**Pilot 4 summary.**

* **Inversion:** the WF `Shift` nested-attributes write into AP `penalty_rules` (§14.2 #9) became the Workforce-defined
  `Shifts::PenaltyRuleSettings` contract implemented by AP `Attendance::ShiftPenaltyRules` (wired at boot); `Shift`
  keeps only the classified lifecycle association (`dependent: :destroy, autosave: true`).
* **Path:** standard — M0, M1, M2, M3, M4, M6, M7, M8; M5 not needed.
* **Remaining (unchanged, not fixed):** P4-D1 (misleading "shift removed" notice when deletion is restricted);
  TD-P4-1 (no audit on rule changes), TD-P4-2 (Float penalty money), TD-P4-3 (rules not effective-dated), TD-P4-4
  (AP rule controllers write directly, legacy API shape); the employee-request consumers (§14.2 #3 / #4) and the
  OA branch staff read (with the OA → WF exception); the stale header comment of
  `spec/services/shifts/penalty_rule_settings_spec.rb` (still describes the M2 delegating implementation; comment
  only, left unchanged as this close-out is docs-only).

**Pilot 4 (Attendance & Payroll Penalty Rules) is COMPLETE.** Nothing was pushed or merged; `main` stays at
`c054fa3`. No next pilot is selected.

### 19.13 Milestone 2 pre-PR gate with Pilot 4 (READY FOR PR)

Read-only milestone review after Pilot 4, including a full-suite run at `ce3ce00` (seed 20261006) compared by exact
failure ID with the `main` @ `c054fa3` run of §18.9 (`main` has not moved since).

| | `ce3ce00` (Pilots 1–4) | `b28110f` (§18.9) | `main` `c054fa3` (§18.9) |
|---|---|---|---|
| Spec files | 570 | 561 | 527 |
| Examples | 7,908 | 7,818 | 7,459 |
| Failures / pending | 94 / 1 | 95 / 1 | 95 / 1 |

* **All 94 failing IDs at `ce3ce00` also fail on `main`.** The only `main`-only ID is
  `spec/system/finance/expense_register_payment_spec.rb:27` (TD-FIN4, documented flaky). Compared with `b28110f`, the
  IDs are the same except TD-FIN5 (`deposit_responsibility_transfer_spec.rb:208`), which passed this time. **No new
  failure ID**; no baseline file changed.
* `origin/main` is an ancestor of `b28110f` and `ce3ce00`: the PR is a conflict-free fast-forward. Every production
  change since `main` maps to a documented `fix:` or pilot commit; no `db/`, migration, route, API or Gemfile change.
* **Branch for the PR:** `feature/milestone-2-attendance-payroll`, after fast-forwarding it to the Pilot 4 close-out
  (it is at `b28110f`, which does not contain Pilot 4).
* **Documentation follow-ups (non-blocking):** the header comment of
  `spec/services/shifts/penalty_rule_settings_spec.rb` still describes the M2 delegating implementation (a spec
  file; not changed in docs-only cleanups). `module-boundaries.md` and the stale status lines here were synchronised
  with Pilots 3–4 in the docs-only consistency cleanup that follows this gate.

## 20. Pilot 5 — Organization & Access ↔ Workforce membership contract

**Status: COMPLETE** (close-out §20.6) on `feature/pilot-5-membership-contract`: M0 (read-only, at `3be2816`), M1
`114f771`, M2 `69031c1`, M3 `5d6b454`, M4 not needed, M5 not needed, M6 `1b5cd65`, M7 not needed, M8 docs. No schema,
migration, route or API change.

### 20.1 M0 summary

* **Scope:** `EmployeeScope`, `BranchScope` (Organization & Access, `module-boundaries.md` §15) and `BranchMembership`
  (Workforce; "implements OA's membership contract"). All three are top-level services in `app/services/`; none has a
  table, association, callback or validation.
* **The OA → WF edges (verified in code; the closeout review was half right):**
  * `EmployeeScope#members_in` → `BranchMembership.current_member_ids` → `ShiftAssignment.user_ids_for_branches`
    (`app/services/employee_scope.rb:134`);
  * `BranchScope#shift_assignment_branch_ids` → `ShiftAssignment.current` **directly**, duplicating
    `BranchMembership.current_branch_ids` (`app/services/branch_scope.rb:83`), only with `include_shift_assignments:
    true` (Laundry / Towel policies and `Laundry::BaseController`).
* **Callers:** `EmployeeScope` — 33 code lines (17 policies incl. `ApplicationPolicy#filter_by_data_scope`, 9
  controllers, 1 view, `Finance::DashboardFilters`); `BranchScope` — 17 (`ApplicationPolicy` helpers, 7 policies, 7
  controllers/services). Other `BranchMembership` callers are WF-internal or AP → WF reads. `BranchMembership.manager_ids`
  has no caller.
* **Out of this pilot's contract (classified, not changed):** the OA branch staff view (`admin/branches_controller`,
  direct `ShiftAssignment`), `User#effective_shift_assignment_on` → `Shifts::AssignmentResolver` (User / Employee
  stewardship), `User` / `Branch has_many :shift_assignments` (inverse associations).
* **Security:** no new finding. OA-S1 – OA-S8 are fixed (OA-S8: `UserPolicy#in_management_scope?`). Business isolation
  rests on `EmployeeScope.base` / `user.business.branches` and the OA-S7 manager validation; no open product decision
  changes scope semantics (SEC-M2-6 / -7 and the SEC-M2-2 follow-up concern which scope particular AP consumers apply).
* **Decision: READY FOR M1** (ownership documented; dependency real; direction documented: OA defines, WF implements —
  `module-boundaries.md` §12.1, §4 item 14; `organization-access-migration-readiness.md` names it `MembershipProvider`).

### 20.2 M1 — characterization

Three new files in `spec/characterization/organization_access/` (51 examples), complementing — not repeating —
`spec/services/employee_scope_spec.rb` (26), `spec/services/branch_scope_spec.rb` (15) and `access_contracts_spec` (16):

| File | Examples | What it pins |
|---|---|---|
| `branch_membership_spec.rb` | 16 | `current_branch_ids` / `current_member_ids` (no direct spec existed): regular and `temporary_coverage`, several branches, expired / future, inclusive bounds, nil branch, inactive users; the **return shape** (a chainable `ShiftAssignment` relation selecting `user_id`, used as `IN (subquery)`); the primitive is **not business-scoped**; the day boundary; `manager_ids` |
| `membership_scopes_spec.rb` | 21 | `BranchScope` shift path ≡ `BranchMembership.current_branch_ids` (branch, area expansion incl. via coverage, de-duplication with management, business isolation, default / self); `EmployeeScope` over membership (coverage, several branches, inactive, other business, working ≠ managing, no role, owner with an explicit scope); `ApplicationPolicy` helpers with every scope value, aliases, unknown / `default` fallbacks, self inclusion, opt-in shift assignments, write-scope checks |
| `membership_scope_consumers_spec.rb` | 14 | One real `Pundit.policy_scope!` consumer per domain: `UserPolicy::Scope` (WF), `PayrollEntryPolicy::Scope` (AP), `ExpensePolicy::Scope` (FS, management only), `TowelTransferPolicy::Scope` (IP / Laundry, shift assignments) — standing in for the API scope specs that fail on `main` for unrelated reasons |

**Behaviour pinned as-is (findings, not changed):**

* **Day boundary:** membership uses `Date.current` of the current `Time.zone` — the business timezone inside web
  requests (`ApplicationController#set_business_timezone`), UTC elsewhere (jobs, console) — and ignores
  `business_day_start_hour` (not `BusinessDay.current`). A later change is a separate approved `fix:`.
* **The membership primitive is not business-scoped:** `current_member_ids` returns any user assigned to the branch;
  isolation comes from `EmployeeScope.base` (pinned).
* **Coverage is membership:** a `temporary_coverage` assignment makes the covering employee visible to the covered
  branch's managers and gives shift-assigned staff that branch (and its area) in Laundry scopes.
* **Inactive users** are included by the primitive and the scopes; callers add `.active`.
* **Own-record asymmetry:** `PayrollEntryPolicy::Scope` omits the viewer's own entry on the hierarchy path (no
  configured scope) but includes it with a configured scope; `UserPolicy::Scope` includes self on both paths.
* **Owner:** `EmployeeScope#for_scope` applies a named scope literally even for the owner; owners get `"business"`
  from `User#scope_for`, so policies never hit that case.
* **`BranchMembership.manager_ids`** works but has no production caller.

**Verification (seed 20261006):** new specs 51 / 0 (also with seeds 12345 and 98765); focused set (80 files, recorded
with its rerun command in `organization-access-membership-baseline-failures.txt`) + new specs: **1,606 examples, 33
failures, 0 pending** — exactly the M0 IDs, none new, none gone. RuboCop clean on the new files.

### 20.3 M2 — membership contract

* **Contract (Organization & Access):** `OrganizationAccess::MembershipProvider`
  (`app/services/organization_access/membership_provider.rb`) — the readiness name. Same shape as
  `Payroll::FinalizationEffects`: `OPERATIONS`, `register` (checks both operations), `NotRegistered` instead of
  resolving to no members, and two operations:
  * `current_branch_ids(user)` → `Array<Integer>` of the user's current branch memberships;
  * `current_member_ids(branch_ids)` → a chainable `ActiveRecord::Relation` selecting `user_id`, used as
    `WHERE id IN (subquery)`, never materialized.

  It names nothing from Workforce and adds no business filtering, date change, authorization decision, scope level or
  `manager_ids`.
* **Implementation (Workforce):** `Workforce::MembershipProvider` (`app/services/workforce/membership_provider.rb`),
  delegating unchanged to `BranchMembership`. It opens the `Workforce::` service boundary in `app/services/workforce/`,
  which `migration-pattern.md` §13 reserves for the first real cross-domain caller.
* **Wiring:** `config/initializers/organization_access_membership_provider.rb` registers the implementation at boot
  (`to_prepare`), so neither domain names the other — the Pilot 3 / Pilot 4 pattern with Organization & Access as the
  defining (upstream) domain.
* **Specs:** `spec/services/organization_access/membership_provider_spec.rb` (10): registration, incomplete provider,
  `NotRegistered`, dispatch and error propagation; through the implementation — regular / coverage / several branches,
  expired / future excluded, the relation's type, model, `select_values` and SQL identical to `BranchMembership`'s, use
  as `IN (subquery)`, the unchanged `Date.current` boundary; and a source check that the contract names no Workforce
  constant.
* **Verification (seed 20261006):** M2 10 / 0 (also seeds 12345 / 98765); M1 51 / 0; focused set + Pilot 5 specs
  **1,616 examples, 33 failures** — exactly the baseline IDs. `zeitwerk:check`, RuboCop and `git diff --check` clean.

**At M2, M3 was next:** routing `EmployeeScope#members_in` and `BranchScope`'s shift-assignment branch ids through
`OrganizationAccess::MembershipProvider` — done in §20.4.

### 20.4 M3 — routing the two membership callers

* `EmployeeScope#members_in` (`app/services/employee_scope.rb`) takes its member ids from
  `OrganizationAccess::MembershipProvider.current_member_ids(ids)` — still used as `IN (subquery)` under
  `EmployeeScope.base` (business isolation unchanged); was `BranchMembership.current_member_ids`.
* `BranchScope#shift_assignment_branch_ids` (`app/services/branch_scope.rb`) takes the user's membership branches from
  `OrganizationAccess::MembershipProvider.current_branch_ids(user)`; the duplicate direct
  `ShiftAssignment.current.where(user_id:)…` query is removed (it was identical to `BranchMembership.current_branch_ids`).
  The area expansion, `include_shift_assignments` opt-in and the public API are unchanged.
* **Dependency after M3:** Organization & Access scope code → `OrganizationAccess::MembershipProvider` (its own
  contract) only; Workforce `Workforce::MembershipProvider` → `BranchMembership` → `ShiftAssignment`. Neither scope file
  names `BranchMembership` or `ShiftAssignment` in code. Enforcement across the codebase is M6.
* **Specs:** `spec/services/organization_access/membership_routing_spec.rb` (9). A planted provider proves the routing
  (members / branches follow the provider, not shift assignments; area expansion uses its branches; business isolation
  still filters its ids; the contract is not consulted for business scope, no branches, or without
  `include_shift_assignments`); with the registered Workforce provider the results and the `IN (subquery)` SQL are as
  before; a source check of both scope files. The M2 contract spec's header comment now points to M3.
* **Verification (seed 20261006):** M3 9 / 0 (also seeds 12345 / 98765); M2 10 / 0; M1 51 / 0; existing scope specs
  (`employee_scope`, `branch_scope`, shift-based membership, Laundry scope requests) 70 / 0; focused set + Pilot 5 specs
  **1,625 examples, 33 failures** — exactly the baseline IDs. `zeitwerk:check`, RuboCop and `git diff --check` clean.
  No behaviour change.

**At M3, next was:** M4 and M6 — see §20.5.

### 20.5 M4 review, M6 boundary enforcement and M7 readiness

**M4 — not needed** (read-only review at `5d6b454`). After M3 the scopes keep only Organization & Access logic
(hierarchy, scope resolution, aliases, permission precedence, business isolation, management ids, area expansion over
`Branch` data); `BranchMembership` (Workforce) is the single owner of membership for the access-scope path; nothing
sits in a non-owning domain. Moving `BranchMembership` into `app/services/workforce/` would only rename its constant.

**M6 — `spec/architecture/organization_access_membership_boundary_spec.rb` (12 examples).** Forbidden names:
`BranchMembership`, `ShiftAssignment`, `Workforce::`, `Shifts::`, `.shift_assignments`, shift-assignment association
macros (comments, `t(...)` keys and the `include_shift_assignments` keyword are not dependencies).

* **Strict, no exception:** `employee_scope.rb`, `branch_scope.rb` and the contract
  (`organization_access/membership_provider.rb`); both scopes read membership through their own contract.
* **Rest of Organization & Access** (46 files: scopes, `organization_access/`, `approvals/`, `Business` / `Branch` /
  `User` / `UserAuditLog` / `PermissionRole`, branch / role / settings admin, web and API sessions, registrations,
  locale, preferences, profile, their policies and views): only the classified exceptions, each limited to its exact
  current lines:

  | File | Class | Allowed lines |
  |---|---|---|
  | `app/models/user.rb` | E + F | `has_many :shift_assignments, dependent: :destroy` (inverse; documented User cascade); `Shifts::AssignmentResolver.for(...)` in `#effective_shift_assignment_on` (User / Employee stewardship helper) |
  | `app/models/branch.rb` | E | `has_many :shift_assignments, dependent: :nullify` |
  | `app/controllers/admin/branches_controller.rb` | F (read-only) | Branch staff view `#show`: current employees (`ShiftAssignment.user_ids_for_branches([ @branch.id ])`, twice) and `@branch.shift_assignments.current` — a cross-domain dashboard (target: Reporting / composition) |
  | `app/controllers/api/v1/sessions_controller.rb` | F (read-only) | Login payload `checkin_branch_ids: ShiftAssignment.current…` — the documented mixed OA / WF / AP session payload (`module-boundaries.md` §17); API unchanged |

  Read exceptions must stay write-free; every exception must still be needed.
* **Composition:** only `config/initializers/organization_access_membership_provider.rb` and `app/services/workforce/`
  name `Workforce::MembershipProvider`; it is the registered provider and implements both operations; it stays a
  delegation to `BranchMembership` and names no Organization & Access scope.
* **Classification of the rest (not enforced here):** downstream readers of `BranchMembership` / `ShiftAssignment` in
  Attendance & Payroll, Finance & Sales, Inventory & Purchasing and Reporting are allowed (B); `BranchMembership`,
  `Workforce::MembershipProvider`, `ShiftAssignmentsController`, `Performance::ReviewAnalytics` are Workforce-internal
  (C); the initializer is wiring (D); specs are test-only (G). **No violation (H) found.**
* **Planted probes:** self-tests stub planted lines (BranchMembership / ShiftAssignment in each scope, `Workforce::` in
  the contract, a `destroy_all` beside an allowed read, a membership read in another Organization & Access file; and
  that comments / i18n keys / the keyword are ignored). On disk, the same kinds of references were added to the real
  files plus a Reporting service naming `Workforce::MembershipProvider`: four rules failed as expected; reverted, green.
* **Verification (seed 20261006):** Pilot 5 specs (M1 + M2 + M3 + M6) 82 / 0 (also seeds 12345 / 98765); all
  architecture 159 / 0; focused set + Pilot 5 specs **1,637 examples, 33 failures** — exactly the baseline IDs.
  `zeitwerk:check`, RuboCop and `git diff --check` clean.

**M7 — NOT NEEDED** (readiness review after M6; approved, not executed). No model is in scope (M7 is a physical model
move). The contract and its implementation already live in their owners' service namespaces
(`app/services/organization_access/`, `app/services/workforce/`). Moving `EmployeeScope`, `BranchScope` or
`BranchMembership` into those namespaced (non-collapsible) folders would rename their constants (67, 31 and 35 code
references), which M7 forbids, for no boundary gain — ownership is expressed by the contract and enforced by M6.

**At M6, next was:** M8 — see §20.6.

### 20.6 M8 — final verification and close-out — Pilot 5 COMPLETE

| Step | Result |
|---|---|
| M0 | COMPLETE — read-only inventory, ownership, semantics, security map, baseline (§20.1) |
| M1 | COMPLETE — `114f771`, 51 characterization examples (§20.2) |
| M2 | COMPLETE — `69031c1`, `OrganizationAccess::MembershipProvider` + `Workforce::MembershipProvider` + boot wiring (§20.3) |
| M3 | COMPLETE — `5d6b454`, `EmployeeScope` / `BranchScope` routed; duplicate `BranchScope` query removed (§20.4) |
| M4 | NOT NEEDED — no logic in a non-owning domain (§20.5) |
| M5 | NOT NEEDED — no business rule in a controller or view; the change is a read-side inversion |
| M6 | COMPLETE — `1b5cd65`, boundary spec, four classified exceptions, planted probes (§20.5) |
| M7 | NOT NEEDED — no model in scope; moving the services would rename constants (§20.5) |
| M8 | COMPLETE — this close-out |

**Final architectural result.**

* Organization & Access owns the membership contract (`app/services/organization_access/membership_provider.rb`);
  Workforce owns the implementation (`app/services/workforce/membership_provider.rb` → `BranchMembership` →
  `ShiftAssignment`); `config/initializers/organization_access_membership_provider.rb` is the only bridge.
* `EmployeeScope` and `BranchScope` consume only the contract; no membership implementation name remains on the
  Organization & Access scope path (enforced, no exception).
* The four exceptions are intentional and documented (§20.5): `User` (inverse association + stewardship helper),
  `Branch` (inverse association), the admin branch staff view and the API login `checkin_branch_ids` (read-only).
* The OA ↔ WF access-scope dependency is inverted; `module-boundaries.md` (§4 item 12, §12.1, §12.2, §13) is synced.

**Final verification (on `1b5cd65`, seed 20261006).**

| Run | Result |
|---|---|
| M1 characterization / M2 contract / M3 routing / M6 boundary | 51 / 10 / 9 / 12 examples, 0 failures (all 82 also with seeds 12345 and 98765) |
| Architecture + Organization & Access characterization + security + API security | 574 examples, 0 failures |
| Focused baseline (80 files) + Pilot 5 specs | **1,637 examples, 33 failures** |

* **Failures:** exactly the 33 IDs in `organization-access-membership-baseline-failures.txt` — none new, none gone
  (`payroll_waive_scope_spec` ×17, `payroll_visibility_spec` ×9, `operations_dashboard_policy_spec:15/16/17`,
  `dashboard_spec:432/460`, `payroll_period_policy_spec:217`, `expense_policy_spec:54`; all also fail on `main`).
* `zeitwerk:check` passes; RuboCop clean on the 11 Ruby files changed since `main`; `git diff --check` clean.
* **No database, schema, migration, route or API change**; production behaviour unchanged (M1 pins it; M2 adds
  delegation only; M3 keeps the same SQL and results; M6 is specs and docs).

**Remaining known limitations (recorded, not fixed):**

* The four classified OA → WF exceptions (branch staff view, login payload, `User` helper and associations).
* Membership uses `Date.current` of the current `Time.zone`, not `BusinessDay.current` (pinned in M1).
* `BranchMembership.current_member_ids` is not business-scoped; isolation is `EmployeeScope.base` (pinned).
* `PayrollEntryPolicy::Scope` omits the viewer's own entry on the hierarchy path (pinned asymmetry).
* About 20 downstream readers compute "current membership" directly from `ShiftAssignment` instead of
  `BranchMembership` (allowed direction; a separate consolidation).
* `BranchMembership.manager_ids` has no caller.
* The API scope specs `payroll_waive_scope_spec` / `payroll_visibility_spec` still fail on `main` for non-scope reasons
  (AP-D2; response shape).

**Pilot 5 (Organization & Access ↔ Workforce membership contract) is COMPLETE.** Nothing was pushed or merged; `main`
stays at `3be2816`.

### 20.7 Pilot 6 recommendation (not started)

**Inventory & Purchasing — Supplier**, as a fast-track pilot (M0 → M1 → M6 → M7 → M8 unless M0 finds a cross-domain
caller). Evidence from the Milestone 2 closeout review: Inventory & Purchasing is the only domain never piloted;
Supplier's 19 external code files are almost all inside the domain (cross-domain only the `Business` inverse
association and the workspace navigation); 0 baseline failures; no open security finding. It validates the pattern in
the fifth domain at low risk before the high-risk Workforce ↔ Attendance & Payroll request cycle (Advances, P-6) or the
Inventory & Purchasing ↔ Finance & Sales settlement cycle. Before selecting it officially: a fresh M0 reference scan,
security probes of the supplier screens, a check of how purchase requests and goods receipts depend on suppliers, and
a focused baseline committed with its set. Integrating Pilot 5 into `main` (PR) should come first.

## 21. Pilot 6 — Inventory & Purchasing Supplier

**Status: COMPLETE** (close-out §21.8): M0 (read-only, at `7f4f422`), security unblock (six `fix:` commits), M1
`bfbb88b`, M2 – M5 not needed, M6 `b34d959`, M7 `3348fbf`, M8 docs. All on `feature/pilot-5-membership-contract`, on
top of Pilot 5, not pushed or merged. No schema, migration, route or API change.

### 21.1 M0 — ownership and dependencies

* **Ownership confirmed: Inventory & Purchasing.** `Supplier` (`app/models/supplier.rb` at M0 — moved in M7 to
  `app/models/inventory_purchasing/supplier.rb`, §21.7; table `suppliers`):
  `belongs_to :business`, `has_many :goods_receipts, dependent: :restrict_with_error`; name / mobile / coordinate
  validations; no `active` / archive or soft-delete column. Administered by `Inventory::SuppliersController` (full CRUD)
  behind the inventory gate and `SupplierPolicy` (read: `view_inventory` / `manage_inventory`; write:
  `manage_inventory` / `manage_suppliers`; scope: business). Routes `resources :suppliers` and the supplier-purchases
  report; no API, job or serializer.
* **No meaningful cross-domain business dependency.** Every consumer is internal to Inventory & Purchasing
  (inventory controllers, services, views, `PurchaseRequest`, `GoodsReceipt`, `Product`, the inventory reports, four
  Stimulus controllers). Outside the domain only: the Organization & Access inverse `Business has_many :suppliers`,
  the `manage_suppliers` permission in the catalogue, and the workspace navigation. Finance & Sales does not read
  `Supplier` (the finance dashboard's supplier block is a disabled placeholder). No cycle runs through `Supplier`; the
  Inventory & Purchasing ↔ Finance & Sales settlement cycle runs through `GoodsReceipt` / `PurchaseRequest` /
  `PurchaseRequestAdvance`, where the supplier is only data.
* **Purchase Requests and Goods Receipts are internal consumers.** Purchase requests own supplier selection
  (`belongs_to :supplier` required, `supplier_in_same_business`, one request per supplier in
  `Inventory::PurchaseRequestCreator`). Goods receipts reference the supplier (optional; inherited from and required to
  match a purchase request) and never write it. `Supplier` owns no purchasing behaviour.

### 21.2 Security unblock — SEC-P6-1 to SEC-P6-6 resolved

Each fix is its own commit with a regression spec in `spec/requests/security/` whose attack cases fail on the previous
code; all mirror the existing `supplier_in_same_business` validation style.

| ID | Severity | Found | Fix | Commit |
|---|---|---|---|---|
| SEC-P6-1 | High | M0 | `GoodsReceipt#supplier_in_same_business` — a standalone receipt could reference another business's supplier (polluting and blocking its deletion) | `7f4f893` |
| SEC-P6-2 | Medium | M0 | `Product#default_supplier_in_same_business` | `7d62798` |
| SEC-P6-3 | Low–Medium | M0 | The supplier page's recent receipts come from `GoodsReceiptPolicy::Scope` (business + accessible warehouses) instead of `Supplier#goods_receipts` — no new authorization logic | `2b69891` |
| SEC-P6-4 | Medium | M1 | `Product#brand_in_same_business` | `4c021d6` |
| SEC-P6-5 | Medium | M1 | `Product#product_category_in_same_business` | `a690d7e` |
| SEC-P6-6 | High | M1 | `Product#parent_product_in_same_business` — a foreign parent used to be written by `propagate_non_tracking_to_parent` (after_save → `force_non_tracking!`, switching off its stock tracking). The validation aborts the save before any callback; the regression spec compares the victim's full row before and after | `35fb7d5` |

### 21.3 M1 — characterization

Three files in `spec/characterization/inventory_purchasing/` (42 examples), complementing the existing purchase-request,
goods-receipt, report and M0/M1 security specs:

| File | Examples | What it pins |
|---|---|---|
| `supplier_admin_spec.rb` | 20 | CRUD (ordering, validations, duplicate names allowed, `business_id` ignored), the permission matrix (`view_inventory` read-only; `manage_inventory`, `manage_suppliers`, owner full; reports-only and no-permission users refused), cross-business 404s, delete rules incl. **P6-D1** |
| `product_references_spec.rb` | 8 | Same-business brand / category / parent accepted; another business's brand, category and parent **refused** (SEC-P6-4/5/6, the victim untouched); a foreign warehouse setting refused (already isolated) |
| `supplier_purchasing_spec.rb` | 14 | Purchase-request supplier rules (required, same business, creator grouping, missing / foreign supplier), receipt rules (optional, must match the request, never writes the supplier), `Supplier`'s structure (only `business` / `goods_receipts`, no callbacks, one method), supplier / purchases / low-stock reports inside the business and the requested warehouses |

**Known defect — P6-D1 (correctness, non-blocking, pinned, not fixed):** deleting a supplier referenced by a product's
default or by a purchase request raises `ActiveRecord::InvalidForeignKey` (a 500) instead of a refusal — `Supplier`
declares only `has_many :goods_receipts, dependent: :restrict_with_error`. Two examples in `supplier_admin_spec.rb`
assert the current behaviour; a fix needs its own approved `fix:`.

**Pre-existing baseline failures (not Pilot 6, not to be fixed here):** `spec/requests/inventory/barcode_labels_spec.rb:36`
and `spec/requests/inventory/products_barcode_spec.rb:50` fail on `main` too and are listed in
`permission-role-baseline-failures.txt`; they appear when the wider product / barcode specs are run, outside the
focused Pilot 6 set.

### 21.4 Verification (M1 close, seed 20261006)

| Run | Result |
|---|---|
| Original M0 focused baseline (60 files: supplier / purchase-request / goods-receipt / inventory request, policy, model, service and system specs, `spec/architecture`, `spec/requests/security`) | **783 examples, 0 failures** |
| Expanded M1 set (+ 13 M0 security regressions + 42 M1 examples) | **838 / 0** |
| Full Pilot 6 set (+ 13 M1 security regressions) | **851 / 0** |
| Architecture + security + API security | **431 / 0** |
| Three-seed check (20261006, 12345, 98765) | M1 42 / 0; M0 regressions 13 / 0; M1 regressions 13 / 0 under every seed |

`zeitwerk:check`, RuboCop and `git diff --check` clean. No new failure.

### 21.5 Migration path

* **M2 – M5 NOT NEEDED** (M1 evidence): no cross-domain caller, no cycle and no cross-domain write through `Supplier`; a
  contract would add nothing; no business rule sits in a controller or another domain.
* **Fast-track M6** — done in §21.6.
* **M7 is a separate decision:** it would be the first physical move into `app/models/inventory_purchasing/` and need a
  new collapse initializer, approved before it is written.

### 21.6 M6 — Supplier boundary enforcement (and M7 readiness)

**Fresh scan** (1,117 `app/` + `lib/` files; code lines only — comments and `t(...)` keys ignored): 182 code lines
reference `Supplier`, `SupplierPolicy`, `suppliers`, `supplier_id` or `default_supplier`, all inside Inventory &
Purchasing — `app/controllers|views|services/inventory/`, `Supplier`, `Product`, `PurchaseRequest`, `GoodsReceipt`,
`SupplierPolicy`, `InventoryHelper`. `Product → Supplier`, `PurchaseRequest → Supplier` and `GoodsReceipt → Supplier` are
internal relationships, not cross-domain edges. **No code outside the domain writes a supplier**, and no Workforce,
Attendance & Payroll, Finance & Sales or Reporting code references one (the finance dashboard's supplier block, the
purchase-request-advance files and `Finance::Dashboard::Capabilities` mention suppliers only in comments). No API.

**Intentional exceptions** (classified, shape-pinned):

| File | Line | Direction / kind | Why allowed |
|---|---|---|---|
| `app/models/business.rb` | 41 | OA → IP, lifecycle | `has_many :suppliers, dependent: :destroy` — the Organization & Access inverse association (documented OA inverse pattern) |
| `app/helpers/workspace_helper.rb` | 158 | UI shell → IP, navigation | The Suppliers menu entry, gated by `policy(Supplier).index?` (the icon key and the `"suppliers"` controller mapping are names, not references) |
| `PermissionRole` catalogue | — | OA, authorization metadata | `manage_suppliers` (depends on `view_inventory`) — a permission name, not a `Supplier` reference; checked by the spec |

**Boundary spec:** `spec/architecture/inventory_purchasing_supplier_boundary_spec.rb` (19 examples). It pins explicit
ownership (model, `Inventory::SuppliersController < Inventory::BaseController`, `SupplierPolicy`); rejects any supplier
reference (constant, policy, controller, collection incl. receiver-less `suppliers.…`, association macros,
`default_supplier`, `supplier_id`) outside an explicit Inventory & Purchasing allow-list and the two shape-pinned
exceptions; rejects supplier writes outside the domain; checks Organization & Access, Workforce, Attendance & Payroll,
Finance & Sales and Reporting code one by one; keeps the allow-list tight; and checks the permission entry and the
`Business` inverse association. Route helpers, i18n keys, the permission name and comments are not flagged.

**Planted probes:** stubbed self-tests (a supplier read in each of the five domains; a supplier write; a widened
`Business` exception; harmless references not flagged; the internal Product / PurchaseRequest / GoodsReceipt
relationships). On disk, supplier reads added to real files of each other domain, a `Supplier.create!` in Finance and a
receiver-less `suppliers.destroy_all` in `Business` failed seven rules as expected; reverted, green. (The probe exposed
that a receiver-less `suppliers.…` call was not matched; the pattern was widened before commit.)

**Production code:** none changed in M6. The six security fixes stay intact (their regression specs pass).

**Verification (seed 20261006):** boundary spec 19 / 0; M1 characterization 42 / 0 and the 26 Pilot 6 security
regression examples 26 / 0 (also seeds 12345 / 98765); full Pilot 6 set **851 / 0**; architecture + security + API
security (now incl. the boundary spec) **450 / 0**; `zeitwerk:check`, RuboCop and `git diff --check` clean. P6-D1 stays
pinned; the barcode baseline IDs are untouched.

**M7 readiness — NEEDED** (read-only review at M6; approved and executed in §21.7). The smallest sensible move is `Supplier` alone:
`app/models/supplier.rb` → `app/models/inventory_purchasing/supplier.rb` (byte-identical), with a new one-line collapse
initializer `config/initializers/inventory_purchasing_autoload.rb` (the first Inventory & Purchasing model folder —
approval needed before it is written), a location spec, and the one allow-list path in the boundary spec. The constant
stays top-level `Supplier` (62 code references unchanged), the table stays `suppliers`, associations resolve by name
(`Product#default_supplier` uses `class_name: "Supplier"`), and nothing references the model file path. No
`InventoryPurchasing` constant exists, and the collapse avoids clashing with the `Inventory::` controller / service
namespace. `Product`, `PurchaseRequest` and `GoodsReceipt` should stay where they are: they are not this pilot's scope
and carry their own cross-domain edges (receipt / advance settlement with Finance & Sales) for later pilots.

### 21.7 M7 — physical move (`3348fbf`)

* `git mv app/models/supplier.rb app/models/inventory_purchasing/supplier.rb` — recorded as a 100 % rename, SHA-256
  identical. The new one-line `config/initializers/inventory_purchasing_autoload.rb` (approved; the first Inventory &
  Purchasing model folder, the Workforce pattern) collapses the folder: the constant stays top-level `Supplier` (no
  `InventoryPurchasing::Supplier`, no clash with the `Inventory::` controller / service namespace), the table stays
  `suppliers`, and every association resolves the same class. No caller changed.
* `spec/architecture/inventory_purchasing_supplier_model_location_spec.rb` (6): location, no top-level file, table, no
  namespace / `Inventory::` untouched, associations (`Business#suppliers`, `Product#default_supplier`,
  `PurchaseRequest#supplier`, `GoodsReceipt#supplier`, `Supplier#business`, `#goods_receipts`), basic behaviour.
* Only the paths followed the move: the M6 boundary spec's allow-list entry and ownership check, and the M1 structure
  check (`supplier_purchasing_spec`).
* **Why M7 was needed:** `Supplier` is the first Inventory & Purchasing model given its domain folder, matching
  Organization & Access, Workforce, Attendance & Payroll and Finance & Sales; the top-level constant made it a pure
  physical move. `Product`, `PurchaseRequest` and `GoodsReceipt` were intentionally **not** moved: they are outside
  this pilot and carry their own concerns (receipt / advance settlement with Finance & Sales) for later pilots.

### 21.8 M8 — close-out — Pilot 6 COMPLETE

| Step | Result |
|---|---|
| M0 | COMPLETE — ownership, dependencies, security probes, baseline (§21.1) |
| Security unblock | COMPLETE — SEC-P6-1 – SEC-P6-6 (§21.2) |
| M1 | COMPLETE — `bfbb88b`, 42 characterization examples (§21.3) |
| M2 – M5 | NOT NEEDED (§21.5) |
| M6 | COMPLETE — `b34d959`, boundary spec (§21.6) |
| M7 | COMPLETE — `3348fbf`, `Supplier` into `app/models/inventory_purchasing/` (§21.7) |
| M8 | COMPLETE — this close-out |

**Final architecture.** Inventory & Purchasing owns `Supplier` (`app/models/inventory_purchasing/supplier.rb`,
top-level constant `Supplier`, table `suppliers`, collapsed by `inventory_purchasing_autoload.rb`). Its consumers —
`Product`, `PurchaseRequest`, `GoodsReceipt`, `SupplierPolicy`, the inventory controllers, services and reports — are
all Inventory & Purchasing concerns. There is no meaningful cross-domain Supplier caller. The intentional external
references are: `Business#suppliers` (Organization & Access lifecycle / inverse association), the workspace navigation
entry (UI composition) and the `manage_suppliers` permission (authorization metadata) — enforced by the M6 boundary
spec.

**Why M2 – M5 were not needed:** no meaningful cross-domain Supplier caller, no Supplier cycle, no cross-domain
Supplier write, no useful contract boundary, and the business logic was already owned by Inventory & Purchasing.

**Security — all six findings resolved** (regression specs in `spec/requests/security/`, each failing on the previous
code): SEC-P6-1 goods receipt → supplier isolation `7f4f893`; SEC-P6-2 product → default supplier `7d62798`; SEC-P6-3
supplier receipt summary scoped by `GoodsReceiptPolicy::Scope` `2b69891`; SEC-P6-4 product → brand `4c021d6`;
SEC-P6-5 product → product category `a690d7e`; **SEC-P6-6 product → parent product `35fb7d5` — the High case**,
because the old behaviour wrote into another business's product (`force_non_tracking!` switched off its stock
tracking).

**Known correctness debt — P6-D1 (NON-BLOCKING, pinned, not fixed):** deleting a supplier referenced by a product's
`default_supplier` or by a purchase request's `supplier` raises `ActiveRecord::InvalidForeignKey` and surfaces as a 500.
Pinned by two examples in `supplier_admin_spec.rb`; left for a future decision.

**Flaky test — TD-P6-1 (unrelated to Pilot 6; spec unchanged):** `spec/requests/inventory/goods_receipt_settlements_spec.rb:63`
failed once in a full Pilot 6 run during M7; the immediate same-seed re-run passed (851 / 0), it passed 6 / 6 in
isolation and 3 / 3 by file, and it passed in the M8 run. It asserts users' full names in the rendered HTML — the
Faker-apostrophe pattern of TD-OA1 / TD-FIN1 / TD-FIN2. Pilot 6 did not modify that spec or the receipt-settlement code.
Not a Pilot 6 regression.

**Pre-existing baseline (not Pilot 6):** `barcode_labels_spec.rb:36` and `products_barcode_spec.rb:50` fail on `main`
too (listed in `permission-role-baseline-failures.txt`); untouched.

**Final verification (on `3348fbf`, seed 20261006):**

| Run | Result |
|---|---|
| Full Pilot 6 focused set | **851 / 0** |
| M1 characterization / security regressions / M6 boundary / M7 location | 42 / 0, 26 / 0, 19 / 0, 6 / 0 — each also with seeds 12345 and 98765 |
| Architecture + security + API security | **456 / 0** (450 + the 6 location examples) |

`zeitwerk:check`, RuboCop and `git diff --check` clean. `module-boundaries.md` status header synced (Inventory &
Purchasing partially migrated).

**Pilot 6 (Inventory & Purchasing — Supplier) is COMPLETE.** Nothing pushed or merged; `main` stays at `3be2816`.

### 21.9 Next-pilot recommendation (not started)

Before another pilot: open the PR integrating Pilots 5 and 6 (and their security fixes) into `main`, and consider the
CI repair (the workflow still runs no RSpec). Then the strongest candidate is **Inventory & Purchasing — product
catalogue (`Brand`, `ProductCategory`)**, fast-track: the domain folder and collapse now exist, Pilot 6 already
characterized and isolated `Product`'s references to both, and both are business-scoped with `restrict_with_error` on
products. A fresh M0 must classify the few references outside `inventory/` (the workspace navigation, and possible name
matches in `finance/daily_reconciliations_controller.rb` and `finance/reports/expense_sources.rb`) and probe their admin
screens. The higher-value, higher-risk alternatives remain the Workforce ↔ Attendance & Payroll request cycle
(Advances) and the Inventory & Purchasing ↔ Finance & Sales settlement cycle.

## 22. Pilot 7 — Inventory & Purchasing Product Catalogue (`Brand`, `ProductCategory`)

**Status: COMPLETE** (close-out §22.7): M0 (read-only, at `067fa00`), M1 characterization, production data check,
M2 – M5 not needed, M6 boundary spec, M7 physical move, M8 close-out — one commit on
`feature/pilot-5-membership-contract`, not pushed or merged. No schema, migration, route or API change.

### 22.1 M0 — ownership and dependencies

* **Ownership confirmed: Inventory & Purchasing.** `Brand` and `ProductCategory` (`app/models/brand.rb`,
  `app/models/product_category.rb`; tables `brands`, `product_categories`) each `belongs_to :business` and
  `has_many :products, dependent: :restrict_with_error`; name required (≤ 120) and unique per business ignoring case
  (model validation + unique index on `(business_id, lower(name))`); `ProductCategory` adds `description` and `active`.
  No callbacks, archive or soft delete. Administered only by `Inventory::BrandsController` /
  `Inventory::ProductCategoriesController` (no show action) behind the inventory gate and `BrandPolicy` /
  `ProductCategoryPolicy` (read: `view_inventory` / `manage_inventory`; write: `manage_inventory` / `manage_products`;
  scope: business). No API, job or serializer.
* **No cross-domain business dependency and no cycle.** Outside Inventory & Purchasing only: the Organization & Access
  inverse `Business has_many :brands / :product_categories, dependent: :destroy` (lifecycle), the workspace navigation
  and the inventory settings hub (UI), and one Reporting read-only display — `Finance::Reports::ExpenseSources` shows a
  consumed product's category name. The suspected match in `finance/daily_reconciliations_controller.rb` (§21.9) no
  longer exists; other hits are false positives ("brand new", CSS `--brand` / `__brand` classes, expense categories).
* **Security: no blocker.** Cross-business edit / update / delete are 404s, lists stay inside the business,
  `business_id` is not permitted, and the Pilot 6 product validations (SEC-P6-4/5/6) are in force. The product CSV
  import finds or creates brands and categories only in the importing business.

### 22.2 M1 — characterization

Four files in `spec/characterization/inventory_purchasing/` (75 examples). Product → brand / category / parent
isolation is **not duplicated**: it stays pinned by `product_references_spec.rb` (Pilot 6 M1) and the regression specs
`product_brand_`, `product_category_` and `product_parent_business_scope_spec.rb` (SEC-P6-4/5/6 — the parent spec
compares the victim product's full row, proving the validation stops the save before
`propagate_non_tracking_to_parent` can write it).

| File | Examples | What it pins |
|---|---|---|
| `brand_admin_spec.rb` | 23 | CRUD (ordering, product counts, redirects / notices, 422 on blank, > 120 or case-insensitive duplicate names, the same name in another business allowed, `business_id` ignored on create and update), restrict-on-delete (used brand kept with the error as the alert, archived products included), the permission matrix (`view_inventory` read-only incl. the forms; `manage_inventory`, `manage_products`, owner full; reports-only and no-permission users refused; `manage_products` requires `view_inventory`), cross-business 404s, model structure and the unique index, **P7-D2** |
| `product_category_admin_spec.rb` | 24 | The same for categories, plus description (free text, optional) and the active flag (default on, editable, deactivation keeps products assigned, status badge on the list) |
| `product_catalogue_usage_spec.rb` | 13 | Product form selectors (own brands; own **active** categories, plus the product's own inactive one on edit), the model does not refuse an inactive category, product-list filters (own brands / active categories; a foreign brand or category id shows nothing), product page display, the six routes per resource (no show) and the settings hub, both models' associations / lack of own callbacks / current location |
| `product_catalogue_import_spec.rb` | 15 | `ProductImporter` resolution: exact-name reuse (spaces stripped), creation once per name, inactive category reused as is, never another business's record of the same name, blank → none; the import screen resolves inside the user's business; a `view_inventory`-only user cannot import; **P7-D1** |

**Known defect — P7-D1 (correctness, Medium, non-blocking, pinned, not fixed):** `ProductImporter` looks brands and
categories up case-sensitively (`find_or_create_by!(name:)`) while their names are unique case-insensitively. A name
differing only in case from an existing one (or from an earlier row of the same file — "Acme" then "acme") fails with
`ActiveRecord::RecordInvalid`, which neither the importer nor the controller rescues: the whole import is rolled back
(nothing saved, which is safe) and Rails maps the error to **422** — production shows the generic `public/422.html`
page, with no import result and no row-level message. (M0 had expected a 500; the M1 characterization shows 422.)
Five examples pin it; a fix needs its own approved `fix:`.

**Known defect — P7-D2 (UI, Low, non-blocking, pinned, not fixed; found in M1):** the six success notices
`inventory.brands.created / updated / destroyed` and `inventory.product_categories.created / updated / destroyed` have
no translation in `en` or `ar`, so after a successful create, update or delete the flash reads
"Translation missing: en.inventory.brands.created". Two examples pin it; a fix (locale keys only) needs its own
approved `fix:`.

**Data check recommended before M6/M7 (read-only, production):** products linked to another business's brand,
category or parent before the Pilot 6 fixes would still exist — they would count on that brand's / category's list
and block its deletion. `Product.joins(:brand).where("brands.business_id <> products.business_id").count`, and the
same for `product_category` and `parent_product`, should be 0.

### 22.3 Verification (M1, seed 20261006)

| Run | Result |
|---|---|
| Focused baseline before M1 (6 directories, `inventory-purchasing-product-catalogue-baseline-failures.txt`) | 2045 examples, **14 failures** (all known), 0 pending |
| Same set after M1 (+ 75) | 2120 examples, **the same 14 IDs**, 0 pending — one run also showed TD-P6-1 (a Faker apostrophe name HTML-escaped); the same-seed re-run passed |
| New M1 characterization, seeds 20261006 / 12345 / 98765 | 75 / 0 under each |
| Security regressions (`spec/requests/security`) + `product_references_spec.rb` | 256 / 0 |

RuboCop clean on the new files. No new failure ID.

### 22.4 Migration path (M1 evidence)

* **M2 – M5 NOT NEEDED:** no cross-domain caller or write, no cycle, no contract would add anything, no business rule
  sits outside Inventory & Purchasing, and the CRUD has no financial state.
* **M6 NEEDED (fast-track) — done in §22.5:** a boundary spec — catalogue writes only inside Inventory & Purchasing; allow-list the
  Organization & Access inverse, the navigation / settings hub and the Reporting read.
* **M7 NEEDED:** move both models into the existing `app/models/inventory_purchasing/` collapse (top-level constants
  kept) with a location spec; `product_catalogue_usage_spec.rb`'s location example is updated then (path only).
* **M8 NEEDED:** close-out. P7-D1 and P7-D2 stay separate decisions.

**Production data check (done before M6):** products linked to another business's brand, category or parent: **0 / 0 / 0**.

### 22.5 M6 — product catalogue boundary enforcement (and M7 readiness)

**Fresh scan** (1,117 `app/` + `lib/` files; code lines only — comments, ERB comments and `t(...)` keys ignored): 67
code lines in 22 files reference `Brand` / `ProductCategory`, their policies or controllers, a brand / category
association, collection or column (41 brand, 31 category). 62 lines in 19 files are inside Inventory & Purchasing —
`app/controllers|views|services/inventory/`, `Brand`, `ProductCategory`, `Product`, `BrandPolicy`,
`ProductCategoryPolicy`. `Product → Brand / ProductCategory` and `ProductImporter`'s find-or-create are internal; all 16
catalogue writes are inside the domain. **No code outside the domain writes a brand or a category** — directly, through
a business collection, by assignment, through nested attributes, callbacks, bulk operations or imports (none exist
outside). No Workforce or Attendance & Payroll reference; `Product` outside the folders is only Laundry (Inventory &
Purchasing, no catalogue use), i18n labels on the home dashboard and the products nav entry. `db/seeds.rb` creates
brands and categories (development seed data, outside `app/` / `lib/`). The `category.save / update / destroy` lines
in `finance/expense_categories_controller.rb` are Finance's `ExpenseCategory` (false positive).

**`Finance::Reports::ExpenseSources` re-verified — Reporting, read-only.** Despite its `finance/` path it is the
cross-domain cost aggregation behind Branch Profitability and Expense Details (payroll from Attendance & Payroll,
consumption from Inventory & Purchasing via `Inventory::ConsumptionLedger`, expenses from Finance & Sales, laundry
costs); `module-boundaries.md` §9 names it as Reporting. Its two catalogue lines preload and read a consumed product's
category name (`includes(:product_category)`, `product&.product_category&.name`) for `finance/reports/_inventory_rows`,
which renders only that string. No save / update / destroy, no callback. Allowed as a read-only exception.

**Classified exceptions** (`spec/architecture/inventory_purchasing_product_catalogue_boundary_spec.rb`, each pinned to
its exact line shape; writes are never excepted):

| File | Kind | Shape |
|---|---|---|
| `app/models/business.rb` | Lifecycle (Organization & Access inverse association) | `has_many :brands, dependent: :destroy`, `has_many :product_categories, dependent: :destroy` |
| `app/helpers/workspace_helper.rb` | Navigation (UI shell) | the inventory Settings entry gated by `policy(ProductCategory).index? \|\| policy(Brand).index? \|\| …` |
| `app/services/finance/reports/expense_sources.rb` | Reporting read | the `includes(:product_category)` preload and the category name |

Not guarded (not business dependencies): route helpers, i18n keys, the `view_inventory` / `manage_inventory` /
`manage_products` permissions (metadata; `manage_products` requires `view_inventory`, asserted), comments, CSS class
names (`--brand`, `__brand`), prose ("brand new"), JavaScript, `config/`, `db/seeds.rb`, specs and docs.

**Prohibited outside Inventory & Purchasing:** `Brand.` / `ProductCategory.` `create | new | insert | upsert | update |
delete | destroy | find_or_create_by | …`; `business.brands.` / `.product_categories.` `create | build | …`;
`brand.` / `product_category.` `update | save | destroy | delete | assign_attributes | touch | …` (so `update_columns`
too); assignment through a receiver (`product.brand = …`, `product.product_category_id = …`); `brand:` /
`product_category:` attributes passed to a write; and `category.save / update / destroy` in any file that names the
catalogue.

**Spec** (31 examples): ownership (models, policies, controllers under the inventory gate); no unexpected reference
outside the domain; no write outside the domain (exceptions included); one check per other domain (Organization &
Access, Workforce, Attendance & Payroll, Finance & Sales, Reporting); allow-list and exception shapes tight (stale
entries and unused shapes fail); the Reporting exception read-only; permission metadata; the lifecycle associations.
Self-tests: a catalogue read planted in each of the five domains; ten planted writes (`Brand.create!`, `brand.update!`,
`brand.destroy!`, `ProductCategory.create!`, `category.update!`, `category.destroy!`, `business.brands.create!`,
`product.brand =`, `Product.create!(product_category: …)`, `brand.update_columns`); widened OA and Reporting
exceptions; harmless references; Product / ProductImporter internal.

**Physical planted probes** (temporary, removed): `app/services/finance/p7_m6_probe.rb` (`Brand.create!`,
`brand.update!`, `brand.destroy!`, `ProductCategory.create!`, `category.update!`, `category.destroy!`),
`app/services/payroll/p7_m6_probe.rb` (`business.product_categories.create!`), `brands.destroy_all` appended to
`business.rb` and `product.product_category.update!` appended to `expense_sources.rb`. With them the spec failed 4
examples (reference rule, write rule, Finance & Sales and Attendance & Payroll checks) and listed each probe line; the
first run also flagged a local `brand = Brand.find(id)` as a write, so assignment now needs a receiver. After removal
(files deleted, the two models restored from git): 31 / 0, no probe code left.

**Verification (seed 20261006):**

| Run | Result |
|---|---|
| M6 boundary spec, seeds 20261006 / 12345 / 98765 | 31 / 0 under each |
| M1 characterization (4 files) | 75 / 0 |
| Security (`spec/requests/security`) + `product_references_spec.rb` | 256 / 0 |
| `spec/architecture` | 215 / 0 |
| Pilot 7 focused set (baseline file's 6 directories) | 2151 examples, **the same 14 baseline IDs**, 0 pending; no TD-P6-1 |

`zeitwerk:check` and RuboCop clean. No new failure ID.

**M7 readiness (assessment only, nothing moved):** `app/models/inventory_purchasing/` is already collapsed by
`config/initializers/inventory_purchasing_autoload.rb`, so `brand.rb` and `product_category.rb` can move there keeping
the top-level constants `Brand` / `ProductCategory`. Neither model sets `table_name` (tables `brands` /
`product_categories` unchanged), so no migration. No code references `InventoryPurchasing::Brand` or
`InventoryPurchasing::ProductCategory`. Path updates needed at M7: `INVENTORY_PURCHASING_FILES` in the M6 spec and the
location example in `product_catalogue_usage_spec.rb`; add a location spec like Supplier's.

### 22.6 M7 — physical move

`Brand` and `ProductCategory` moved with `git mv` (both detected as `R100`, byte-identical):
`app/models/brand.rb` → `app/models/inventory_purchasing/brand.rb`, `app/models/product_category.rb` →
`app/models/inventory_purchasing/product_category.rb`. The existing `config/initializers/inventory_purchasing_autoload.rb`
(Pilot 6) already collapses the folder, so no new initializer: the constants stay top-level `Brand` / `ProductCategory`,
there is no `InventoryPurchasing::Brand` / `::ProductCategory` (no `InventoryPurchasing` constant at all), tables stay
`brands` / `product_categories` (no `table_name` set), associations, validations and scopes unchanged. No migration, no
`db/` change.

Path-only updates: `INVENTORY_PURCHASING_FILES` in the M6 boundary spec (rules unchanged) and the location example in
`product_catalogue_usage_spec.rb`. New `spec/architecture/inventory_purchasing_product_catalogue_model_location_spec.rb`
(11 examples, the Supplier pattern): each model loads as a top-level constant from the folder, the old file is gone, the
table is kept, no `InventoryPurchasing` / `Inventory::` constant, controllers stay `Inventory::`, every association
resolves the same class, behaviour kept (business scoping, case-insensitive uniqueness, the active scope, restrict on
products). A planted probe re-run after the path update (`Brand.create!` and `ProductCategory.find(id).destroy!` in a
temporary Finance service) failed 3 boundary examples; removed afterwards.

**Verification:**

| Run | Result |
|---|---|
| Location + M6 boundary, seeds 20261006 / 12345 / 98765 | 42 / 0 under each |
| M1 characterization, seeds 20261006 / 12345 / 98765 | 75 / 0 under each |
| Security (`spec/requests/security`) + `product_references_spec.rb` | 256 / 0 |
| `spec/architecture` | 226 / 0 |
| Pilot 7 focused set (seed 20261006) | 2162 examples, **the same 14 baseline IDs**, 0 pending; no TD-P6-1 |

`zeitwerk:check`, RuboCop on the changed files (12, no offenses) and `git diff --check` clean.

### 22.7 M8 — close-out — Pilot 7 COMPLETE

| Step | Result |
|---|---|
| M0 | COMPLETE — ownership, dependencies, security probes, baseline (§22.1) |
| M1 | COMPLETE — 4 characterization files, 75 examples (§22.2 – §22.3) |
| Production data check | COMPLETE — cross-business product → brand / category / parent links: 0 / 0 / 0 |
| M2 – M5 | NOT NEEDED (§22.4) |
| M6 | COMPLETE — boundary spec, 31 examples (§22.5) |
| M7 | COMPLETE — `Brand`, `ProductCategory` into `app/models/inventory_purchasing/`, location spec (§22.6) |
| M8 | COMPLETE — this close-out |

**Final architecture.** Inventory & Purchasing owns `Brand` (`app/models/inventory_purchasing/brand.rb`, table
`brands`) and `ProductCategory` (`app/models/inventory_purchasing/product_category.rb`, table `product_categories`),
next to `Supplier`; top-level constants, collapsed by `inventory_purchasing_autoload.rb`, no `InventoryPurchasing`
namespace. Their consumers — `Product`, `Inventory::Imports::ProductImporter`, `BrandPolicy`, `ProductCategoryPolicy`,
the inventory controllers, views and services — are Inventory & Purchasing concerns. The intentional external
references are `Business#brands` / `#product_categories` (Organization & Access lifecycle), the inventory Settings
navigation entry (UI) and the Reporting read in `Finance::Reports::ExpenseSources` (category name) — enforced by the
M6 boundary spec, which also forbids any catalogue write outside the domain.

**Why M2 – M5 were not needed:** no cross-domain catalogue caller or write, no cycle, no useful contract boundary, and
all catalogue logic was already in Inventory & Purchasing.

**Security:** the Pilot 6 protections remain in force and green — product → brand (SEC-P6-4), product → category
(SEC-P6-5), product → parent product (SEC-P6-6, the victim row unchanged); no new finding in Pilot 7.

**Known debt (pinned, not fixed; each needs its own approved `fix:`):**

* **P7-D1 (Medium, correctness):** `ProductImporter`'s exact-case brand / category lookup conflicts with their
  case-insensitive uniqueness — a name differing only in case raises `ActiveRecord::RecordInvalid`, the import rolls
  back, and the user gets Rails' generic 422 page.
* **P7-D2 (Low, UI):** the English and Arabic success notices for brand and category create / update / delete are
  missing ("Translation missing: …").
* **Baseline:** the 14 IDs in `inventory-purchasing-product-catalogue-baseline-failures.txt` are untouched.
* **TD-P6-1** (flaky, `goods_receipt_settlements_spec.rb:63`) stays known debt; it appeared once in M0 and once in M1
  (both passed on same-seed re-runs), not in M6 – M8.

**Final verification:**

| Run | Result |
|---|---|
| Pilot 7 focused set, seeds 20261006 / 12345 / 98765 | 2162 examples, **the same 14 baseline IDs** under each, 0 pending, no TD-P6-1 |
| Location + boundary | 42 / 0 |
| M1 characterization | 75 / 0 |
| Security (`spec/requests/security`) + `product_references_spec.rb` | 256 / 0 (product-reference subset 21 / 0) |
| `spec/architecture` | 226 / 0 |
| Planted probe (`business.brands.create!` in a temporary Payroll service) | 3 boundary failures; removed → 31 / 0 |

`zeitwerk:check`, RuboCop on the changed files and `git diff --check` clean. `module-boundaries.md` status header
synced (Inventory & Purchasing: `Supplier`, `Brand`, `ProductCategory`).

**Pilot 7 (Inventory & Purchasing — Product Catalogue) is COMPLETE.** Nothing pushed or merged.

## 23. Pilot 8 — Workforce Employee Insurance Profile

**Status: COMPLETE** (close-out §23.10): M0 (read-only, at `main` `4655d18`), security unblock `8c0cdc8` / `d100b38`,
M1 `85b7966`, M2 `68f6c05`, M3 `ca8a05f`, M4 / M5 not needed, M6 `7d9156a`, M7 `cb6dcf0`, M8 docs — on
`fix/pilot-8-insurance-security`, not pushed or merged. No schema, migration, route, API or Booking change.

### 23.1 M0 — selection and ownership

* **Why this candidate:** the Workforce ↔ Attendance & Payroll cycle is the largest remaining one
  (`module-boundaries.md` §12.2 / §14.2 #2 – #5); its smallest separable edge is #5 —
  `Employee::InsuranceProfileUpdater` commands `Payroll::EntryRecalculator`. Advances (#2) and the request effects
  (#3, #4) carry open security / product decisions (SEC-M2-7, SEC-M2-2) and high atomicity risk; the Inventory &
  Purchasing ↔ Finance & Sales settlement (#6) has grown to ~24 files and moves money; POS terminals (#8), warehouse
  access (#10) and the laundry labour-cost report touch no cycle or little.
* **Ownership: Workforce** (`module-boundaries.md` §5, §10.1): `EmployeeInsuranceProfile` (table
  `employee_insurance_profiles`), `Employee::InsuranceProfileUpdater`, `Admin::EmployeeInsuranceProfilesController`,
  `EmployeeInsuranceProfilePolicy`, the employee-page Social Insurance card. Attendance & Payroll only reads it
  (`Payroll::EntryCalculator` snapshot).
* **Security blockers (M0, both fixed before M1):**

| ID | Severity | Finding | Fix | Commit |
|---|---|---|---|---|
| SEC-P8-1 | High | `GET …/employee_insurance_profile/edit` by any same-business admin-gate user outside the insurance scope **deleted** the employee's profile (no audit): `set_profile` fell back to `@employee.build_employee_insurance_profile`, and `User has_one :employee_insurance_profile, dependent: :destroy` removes the existing row when building | A standalone unsaved `EmployeeInsuranceProfile.new(user:, business:)` | `8c0cdc8` |
| SEC-P8-2 | Medium | A `manage_employee_insurance` holder scoped to self / branch could create or update any same-business employee's profile (`create?/update?` checked only the flag) | `create?/update?` require the employee inside the same insurance scope `Scope#resolve` uses (`EmployeeScope#for_permissions(:manage_employee_insurance, :view_employee_insurance)`, own profile included); one existing policy example that assumed "no scope = any employee" adjusted | `d100b38` |

Regression specs: `spec/requests/security/employee_insurance_profile_deletion_spec.rb` (5; 3 fail on the old code),
`employee_insurance_profile_scope_spec.rb` (10; 5 fail on the old code).

### 23.2 M1 — characterization

Three files in `spec/characterization/workforce/` (44 examples), complementing the existing updater, request, policy,
`EntryCalculator` / `EntryRecalculator` specs and the two security specs:

| File | Examples | What it pins |
|---|---|---|
| `employee_insurance_profile_lifecycle_spec.rb` | 19 | Model: defaults (not insured, zero amounts), start date required only when insured, amounts ≥ 0, end ≥ start (same day allowed), contributions zeroed when not insured, one profile per employee (+ unique index), `covers_period?` window, associations and the OA inverses. Updater: create (business from the employee, `created_by` the actor, all attributes), update in place (`created_by` kept), switching to not insured, audits `insurance_profile_created` / `_updated` with before / after of six fields (notes excluded), an invalid change → `ok: false`, nothing saved, audited or recalculated; another business's employee → `ok: false` (RecordNotFound); the updater does no authorization (callers authorize); the recalculation call (`recalculate_all_open_periods_for(user:, triggered_by:)`, once per successful save, even unchanged; after the commit — a raising recalculation leaves profile and audit, logs, `ok: true`) |
| `employee_insurance_profile_admin_spec.rb` | 16 | Update → redirect to the employee page with the notice, all permitted fields, `business_id` / `user_id` / `created_by_id` ignored, invalid → 422 nothing saved, edit form values; the card: manager sees status, both contributions, dates, number, Edit; open end → "—", no number row; view-only sees no employer contribution and no Edit; no profile / not insured → "Not insured."; no insurance permission → no card; Edit per scope (branch: own branch only; self: never on another page; business: everyone); **P8-D1**; cross-business 404s |
| `employee_insurance_payroll_snapshot_spec.rb` | 9 | `EntryCalculator` reads the profile: insured + both amounts + number snapshotted; one `insurance_deduction` line item of −employee amount sourced from the profile; only the employee amount reduces net salary; no profile / not insured / coverage after / before the period → not insured, zeros, no number, no item; partial overlap → full amounts (no proration); the profile is never written |

**Known debt — P8-D1 (security, Low–Medium, pinned, not fixed):** the employee-page card is gated by
`EmployeeInsuranceProfilePolicy#show?`, which checks only the permission (`viewable?`), not the insurance scope. A
user who can open an employee's page (`view_employees` scope) but whose insurance scope excludes that employee still
sees the card and amounts — a manager also the employer contribution. Read-only; a fix needs its own approved `fix:`.

### 23.3 Current dependency edges (classified, unchanged in M1)

| # | Edge | Kind | Where |
|---|---|---|---|
| 1 | Workforce → Attendance & Payroll | **Business write (command)** — recalculates open payroll entries | `employee/insurance_profile_updater.rb:59` → `Payroll::EntryRecalculator.recalculate_all_open_periods_for` |
| 2 | Workforce → Attendance & Payroll | **Business read** (UI) — which payroll periods an edit affects (notice) | `admin/employee_insurance_profiles_controller.rb` `set_payroll_notice` (`PayrollPeriod`, `@employee.payroll_entries`, `locked?`) |
| 3 | Attendance & Payroll → Workforce | **Business read** (allowed direction) — snapshot at entry generation | `payroll/entry_calculator.rb` `resolve_insurance_snapshot` (`@user.employee_insurance_profile`, `covers_period?`) |
| 4 | Organization & Access → Workforce | **Lifecycle association** | `business.rb:77` `has_many :employee_insurance_profiles, dependent: :destroy` |
| 5 | Organization & Access → Workforce | **Lifecycle association** | `user.rb:50` `has_one :employee_insurance_profile, dependent: :destroy` |
| — | Workforce UI | **UI / read concern** | `admin/users/show.html.erb` card (P8-D1) |

### 23.4 Verification (seed 20261006)

| Run | Result |
|---|---|
| M0 set (`main`) | 626 / 0 |
| After the security unblock (`workforce-insurance-profile-baseline-failures.txt` set before M1) | 641 / 0 |
| + M1 (44) | **685 / 0**, 0 pending |
| M1 files, seeds 20261006 / 12345 / 98765 | 44 / 0 under each |
| `spec/requests/security` | 263 / 0 |
| `spec/architecture` | 226 / 0 |

`zeitwerk:check` and RuboCop clean.

### 23.5 Migration path (M1 evidence)

* **M2 NEEDED:** a Workforce-defined contract for the payroll effect of an insurance change (edge 1) and the
  payroll-notice query (edge 2), implemented by Attendance & Payroll and registered at boot (the Pilot 4
  `Shifts::PenaltyRuleSettings` pattern). Its contract must keep: call after the profile and audit are committed, once
  per successful save, never on a failed save, a raising implementation never fails the change.
* **M3 NEEDED:** route the updater and the controller notice through the contract.
* **M4 / M5 NOT NEEDED (expected):** the recalculation logic is already in Attendance & Payroll; the updater is already a
  service.
* **M6 NEEDED:** boundary spec — Workforce reaches Attendance & Payroll only through the contract; Attendance & Payroll
  may read the profile (edge 3); OA inverses shape-pinned.
* **M7 NEEDED:** `EmployeeInsuranceProfile` → `app/models/workforce/` (collapsed, top-level constant).
* **M8 NEEDED.**

### 23.6 M2 — Workforce contract `Employee::InsuranceProfileEffects`

**Decision: one contract, two operations.** The edit-form notice and the recalculation describe the same thing — the
payroll an insurance change affects. The notice's open periods (not `locked?`, i.e. not finalized / paid, with an entry
for the employee) are exactly the periods `Payroll::EntryRecalculator.recalculate_all_open_periods_for` re-derives. A
preview and its application of one effect; not a general payroll facade, nothing else added.

| | |
|---|---|
| Contract (Workforce) | `Employee::InsuranceProfileEffects` — `app/services/employee/insurance_profile_effects.rb`; names nothing from Attendance & Payroll (asserted by its spec) |
| `profile_changed(user:, actor:)` | `user`: the employee (`User`), `actor`: the `User` who saved the profile. Returns `nil` — nothing crosses back. Handler errors propagate; the caller isolates them |
| `payroll_notice_for(user:)` | Returns a `Symbol` in `NOTICES = %i[none active mixed finalized]` — the value the edit view already renders. Anything else (a payroll record, a relation, a String, `nil`) raises `ArgumentError`, so no Attendance & Payroll object crosses the contract |
| Registration | `register(handler)` rejects a handler missing either operation; no handler → `NotRegistered` (a `StandardError`), never a silent skip |
| Implementation (Attendance & Payroll) | `Payroll::InsuranceProfileEffects` — `app/services/payroll/insurance_profile_effects.rb`: `profile_changed` = `Payroll::EntryRecalculator.recalculate_all_open_periods_for(user:, triggered_by: actor)`; `payroll_notice_for` = the controller's current `set_payroll_notice` rule, unchanged |
| Wiring | `config/initializers/employee_insurance_profile_effects.rb` (`to_prepare`, the Pilot 4 composition-root pattern) |

**Synchronous, after commit, failure isolated — kept, not moved into the contract.** No job or event bus: M1 pins a
synchronous call made after the profile and its audit are committed, once per successful save, with a raising
recalculation logged by the updater and the change still `ok: true`. The contract therefore only dispatches and
propagates errors; in M3 the updater calls `profile_changed` from where it calls the recalculator today, inside its
existing `rescue` (same log message), so every M1 example keeps passing unchanged. The Attendance & Payroll read of the
profile (`EntryCalculator#resolve_insurance_snapshot`, edge 3) stays as it is — the allowed direction.

**Callers not changed in M2:** `Employee::InsuranceProfileUpdater` still called `Payroll::EntryRecalculator` and the
controller still computed the notice itself (the implementation duplicated the notice rule) until M3 (§23.7).

**Spec:** `spec/services/employee/insurance_profile_effects_spec.rb` (16) — registration (implementation registered at
boot, incomplete handler rejected, `NotRegistered`), dispatch (user and actor passed unchanged, `nil` returned, errors
propagate, notice passed through, non-notice return values rejected), the implementation (open periods recalculated,
locked untouched; same call and arguments as the updater's; the four notices; other employees ignored), parity with
the edit form's notice in every state, and no Attendance & Payroll name in the contract.

**Verification (seed 20261006):** Pilot 8 set + the contract spec 701 / 0 (685 + 16); M1 characterization 44 / 0;
`spec/requests/security` 263 / 0; `spec/architecture` 226 / 0; Pilot 4 / Milestone 2 contract specs
(`penalty_rule_settings`, `shift_penalty_rules`, `finalization_effects(_routing)`, the penalty-rule shift form) 47 / 0;
contract + M1 under seeds 12345 / 98765 60 / 0. `zeitwerk:check`, RuboCop and `git diff --check` clean.

**M3 (next, not started):** route `Employee::InsuranceProfileUpdater#recalculate_open_periods` and
`Admin::EmployeeInsuranceProfilesController#set_payroll_notice` through the contract; no behaviour change.

### 23.7 M3 — routing the two Workforce callers

| Caller | Before | After |
|---|---|---|
| `Employee::InsuranceProfileUpdater#recalculate_open_periods` | `Payroll::EntryRecalculator.recalculate_all_open_periods_for(user:, triggered_by: @actor)` | `Employee::InsuranceProfileEffects.profile_changed(user:, actor: @actor)` — same place (after the transaction), same `rescue` and log message |
| `Admin::EmployeeInsuranceProfilesController#set_payroll_notice` | `PayrollPeriod` / `@employee.payroll_entries` / `locked?` rule inline | `@payroll_insurance_notice = Employee::InsuranceProfileEffects.payroll_notice_for(user: @employee)` |

Neither file names `Payroll::`, `PayrollPeriod`, `PayrollEntry`, `payroll_entries` or `EntryRecalculator` any more; the
notice rule (and its explanation) lives only in `Payroll::InsuranceProfileEffects`. Edge 1 and edge 2 of §23.3 now go
through the Workforce contract; edge 3 (`EntryCalculator` reads the profile) and the OA inverses are unchanged.
Contract, authorization, audit, `EntryCalculator`, routes and schema unchanged.

**Spec:** `spec/services/employee/insurance_profile_effects_routing_spec.rb` (8; 6 fail on the pre-M3 callers) — a
successful save calls `profile_changed` once with the employee and actor after the profile and audit are committed
(no transaction open beyond the test's own); through the registered implementation the recalculation call and
arguments are unchanged; a failed save never calls it; a raising handler (and `NotRegistered`) is rescued with the
same log line, profile and audit kept, `ok: true`; the edit form and the re-rendered update form render whatever notice
the contract returns, for the edited employee; neither caller names Attendance & Payroll.

**Verification (seeds 20261006 / 12345 / 98765, identical):** Pilot 8 set + contract + routing 709 / 0 (701 + 8); M1
characterization 44 / 0; contract + routing 24 / 0; `spec/requests/security` 263 / 0 (SEC-P8-1 / SEC-P8-2 unchanged);
`spec/architecture` 226 / 0; Pilot 4 / Milestone 2 contract specs 47 / 0. `zeitwerk:check`, RuboCop and
`git diff --check` clean.

**Next:** M4 / M5 not needed (the payroll logic already lives in Attendance & Payroll; the updater is already a
service). M6 boundary enforcement is ready.

### 23.8 M6 — Workforce employee insurance profile boundary

`spec/architecture/workforce_employee_insurance_profile_boundary_spec.rb` (22 examples; the source-scanning style of the
Pilot 4 – 7 boundary specs — comments, ERB comments and `t(...)` keys ignored):

| Rule | Enforced |
|---|---|
| 1 | Workforce insurance-profile code — the model, `Employee::InsuranceProfileUpdater`, the contract, `Admin::EmployeeInsuranceProfilesController`, `EmployeeInsuranceProfilePolicy`, `app/views/admin/employee_insurance_profiles/`, and the Social Insurance section of `admin/users/show.html.erb` (from its `<%# Social Insurance %>` marker to the next section) — names no `Payroll::` / `Attendance::` constant (`EntryRecalculator`, the contract implementation, …), `PayrollPeriod` / `PayrollEntry` / `PayrollLineItem`, `payroll_periods` / `payroll_entries` / `payroll_line_items`, or `locked?` — the references removed in M3. `Employee::InsuranceProfileEffects` is allowed |
| 2 | The two M3 callers call the contract exactly once each: the updater `profile_changed(`, the controller `payroll_notice_for(` |
| 3 | `Payroll::InsuranceProfileEffects` is named only by `config/initializers/employee_insurance_profile_effects.rb` (`app/`, `lib/`, `config/` scanned) |
| 4 | Outside Workforce, `EmployeeInsuranceProfile` / `employee_insurance_profile(s)` appears only at three exact line shapes: `business.rb` `has_many :employee_insurance_profiles, dependent: :destroy` and `user.rb` `has_one :employee_insurance_profile, dependent: :destroy` (Organization & Access lifecycle), and `payroll/entry_calculator.rb` `profile = @user.employee_insurance_profile` (the Attendance & Payroll snapshot read — the allowed direction, not a contract) |
| 5 | Nothing outside Workforce writes the profile (class writers, `employee_insurance_profile(&).update/save/destroy/…`, collection builders, `build_employee_insurance_profile`, assignment; `profile.update/save/…` counted only in files that name the insurance profile) |
| — | Allow-lists tight (files exist, every exception shape still matches, the card section is found); the OA associations are lifecycle-only (`dependent: :destroy`, nothing else) |

Not scanned: the employee page's salary card (`SalaryProfile` — the separate, documented WF → AP salary-display edge,
SEC-M2-5), route helpers, i18n keys, permission names, JavaScript, `config/` (other than rule 3).

**Probes.** In-spec self-tests (stubbed file reads): `Payroll::EntryRecalculator`, `Payroll::InsuranceProfileEffects`,
`PayrollPeriod`, `PayrollEntry`, `payroll_entries`, `locked?` and an `Attendance::` service planted in each caller are
caught; a payroll query planted in the card section is caught but not in the salary section; the contract itself is
allowed; a swapped contract operation, the implementation named elsewhere, a widened lifecycle line, a write next to the
payroll read (incl. `&.`), and a new reference from another domain are caught; route helpers, i18n keys, comments and the
`@payroll_insurance_notice` variable are not. **Physical probes** (temporary, removed with `git checkout` / `rm`):
`Payroll::EntryRecalculator` appended to the updater, `PayrollPeriod` to the controller,
`employee_insurance_profile&.update` to `user.rb`, and a Finance service naming `Payroll::InsuranceProfileEffects` — 4
rule examples failed, each listing its probe line (the first run also exposed that `&.` writes were missed; the write
pattern now covers them). After cleanup: 22 / 0, no probe code left.

No production code changed in M6; no new dependency found. `module-boundaries.md`: §5 dependencies, §12.1 inversion
table, §12.2 WF → AP row and §14.2 #5 record the resolved edge.

**Verification (seeds 20261006 / 12345 / 98765, identical):** boundary 22 / 0; Pilot 8 set + contract + routing 731 / 0
(709 + 22); M1 44 / 0; contract + routing 24 / 0; `spec/requests/security` 263 / 0; `spec/architecture` 248 / 0 (226 + 22);
Pilot 4 / Milestone 2 contract specs 47 / 0. `zeitwerk:check`, RuboCop, `git diff --check` clean.

**M7 (next, not started):** `EmployeeInsuranceProfile` → `app/models/workforce/` (collapsed by `workforce_autoload.rb`,
top-level constant and table unchanged); rule 1's model path and the Pilot 4 spec's `WORKFORCE_GLOBS` entry then need
the new path.

### 23.9 M7 — physical move

`git mv app/models/employee_insurance_profile.rb app/models/workforce/employee_insurance_profile.rb` (`R100`,
byte-identical). The existing `config/initializers/workforce_autoload.rb` collapse (Department / JobTitle, Performance)
covers it: the constant stays top-level `EmployeeInsuranceProfile` (`Workforce::EmployeeInsuranceProfile` is not
defined — `Workforce` exists only as the service namespace of `Workforce::MembershipProvider`), the table stays
`employee_insurance_profiles`; `User#employee_insurance_profile` and `Business#employee_insurance_profiles` resolve the
same class. No reference was rewritten; no migration, schema, route, service, contract or policy change.

Path-only spec updates: the Pilot 8 boundary spec's `WORKFORCE_FILES` model path (rules unchanged); the Pilot 4
penalty-rule spec's `WORKFORCE_GLOBS` drops `employee_insurance_profile` from its `app/models/{…}.rb` list — the model is
now covered by its `app/models/workforce/**/*.rb` glob (verified: the new path is scanned, the old is not).
`spec/architecture/workforce_model_location_spec.rb` (the shared Workforce location spec, as for the earlier Workforce
moves) gains `EmployeeInsuranceProfile => "employee_insurance_profiles"` (top-level constant from the folder, table, not
namespaced under `Workforce`), the `User` / `Business` association classes, and old-file-gone / new-file-present.
A planted payroll reference in the moved model failed rule 1 of the boundary spec; restored byte-identical.

**Verification (seeds 20261006 / 12345 / 98765, identical):** Workforce location 26 / 0 (22 + 4); boundary 22 / 0; Pilot
8 set + contract + routing 735 / 0; M1 44 / 0; contract + routing 24 / 0; `spec/requests/security` 263 / 0;
`spec/architecture` 252 / 0 (248 + 4); Pilot 4 / Milestone 2 contract specs 47 / 0. `zeitwerk:check`, RuboCop,
`git diff --check` clean. `module-boundaries.md` status header lists `EmployeeInsuranceProfile` under Workforce.

### 23.10 M8 — close-out — Pilot 8 COMPLETE

| Step | Result |
|---|---|
| M0 | COMPLETE — candidate selection (§23.1); found SEC-P8-1 / SEC-P8-2 → NOT READY |
| Security unblock | COMPLETE — SEC-P8-1 `8c0cdc8` (High), SEC-P8-2 `d100b38` (Medium) |
| M1 | COMPLETE — `85b7966`, 44 characterization examples (§23.2) |
| M2 | COMPLETE — `68f6c05`, Workforce contract `Employee::InsuranceProfileEffects` (§23.6) |
| M3 | COMPLETE — `ca8a05f`, both Workforce callers routed through it (§23.7) |
| M4 / M5 | NOT NEEDED — payroll logic already in Attendance & Payroll; the updater already a service |
| M6 | COMPLETE — `7d9156a`, boundary spec (§23.8) |
| M7 | COMPLETE — `cb6dcf0`, `EmployeeInsuranceProfile` → `app/models/workforce/` (§23.9) |
| M8 | COMPLETE — this close-out |

**Final architecture.** Workforce owns `EmployeeInsuranceProfile` (`app/models/workforce/employee_insurance_profile.rb`,
top-level constant, table `employee_insurance_profiles`), `Employee::InsuranceProfileUpdater`,
`Admin::EmployeeInsuranceProfilesController`, `EmployeeInsuranceProfilePolicy`, the insurance form and the employee
page's Social Insurance card, and the contract `Employee::InsuranceProfileEffects` (`profile_changed`,
`payroll_notice_for`). Attendance & Payroll implements the contract (`Payroll::InsuranceProfileEffects`, registered in
`config/initializers/employee_insurance_profile_effects.rb`) and keeps reading the profile for its snapshot
(`Payroll::EntryCalculator#resolve_insurance_snapshot`, the allowed direction). Organization & Access keeps the
lifecycle associations `Business#employee_insurance_profiles` and `User#employee_insurance_profile`. Enforced by
`workforce_employee_insurance_profile_boundary_spec.rb` (22) and `workforce_model_location_spec.rb`.

```
Workforce ── Employee::InsuranceProfileEffects (WF contract) ──▶ Attendance & Payroll (Payroll::InsuranceProfileEffects)
Attendance & Payroll ── EntryCalculator reads EmployeeInsuranceProfile ──▶ Workforce   (allowed read)
Organization & Access ── Business / User has_many / has_one (dependent: :destroy) ──▶ Workforce   (lifecycle)
```

**Cycle reduction:** of the Workforce → Attendance & Payroll edges in `module-boundaries.md` §14.2, #5 (insurance
recalculation) and the insurance form's payroll read are resolved; #2 – #4 (advances, punch correction, request
cancellation) and the salary display remain.

**Final verification (on `cb6dcf0`):**

| Run | Result |
|---|---|
| Pilot 8 set (`workforce-insurance-profile-baseline-failures.txt`) + contract + routing, seeds 20261006 / 12345 / 98765 | **735 / 0** under each |
| Boundary + Workforce location | 48 / 0 under each seed |
| M1 characterization / contract + routing / SEC-P8 regressions | 44 / 0, 24 / 0, 15 / 0 under each seed |
| `spec/requests/security` / `spec/architecture` | 263 / 0, 252 / 0 under each seed |
| Full suite (seed 20261006) | 8309 examples, 95 failures, 1 pending — 87 in the documented baseline files; 7 listed in §18.9 as failing on `main` (`expense_amount_distribution_spec:28`, `purchase_request_form_spec` ×6); 1 **TD-OA1** (`permission_roles_spec.rb:28`, Faker apostrophe name HTML-escaped; passes alone). None touches Pilot 8 code |

`zeitwerk:check`, RuboCop (18 Ruby files changed since `main`) and `git diff --check` clean.

**Known debt (pinned / recorded, not fixed):**

* **P8-D1 (security, Low–Medium):** the employee-page card is gated by `EmployeeInsuranceProfilePolicy#show?`
  (permission only), not the insurance scope — pinned in `employee_insurance_profile_admin_spec.rb`.
* `Employee::InsuranceProfileUpdater` does no authorization itself; its only caller authorizes first (pinned in M1).
* SEC-M2-5 / -6 / -7 and AP-D1 (salary and advances) remain open, outside this pilot.
* TD-OA1 remains known flaky debt.

**Pilot 8 (Workforce — Employee Insurance Profile) is COMPLETE.** Nothing pushed or merged; the seven commits plus this
close-out sit on `fix/pilot-8-insurance-security` on top of `main` `4655d18`.

## 24. Pilot 9 — Workforce Request Permission Payroll Effects (late / early-leave permissions)

**Status: COMPLETE** (close-out §24.9): M0 (read-only, at `main` `a9f8ff3`), security unblock `09957e9` / `0512fc6`,
M1 `c0cd7ff`, M2 `27fe23a`, M3-A `2d55172`, M3-B + M4 `2663590`, M6 `cc8fe42`, M7 not needed, M8 docs — on
`fix/pilot-9-request-scope`, not pushed or merged. No schema, migration, route, API or Booking change.

### 24.1 M0 — selection

* **Why this candidate:** after Pilot 8 the Workforce ↔ Attendance & Payroll request cycle is the largest remaining one
  (`module-boundaries.md` §14.2 #2 – #4). Its smallest write edge is the payroll effect of late / early-leave
  permissions: approval calls `Payroll::PermissionApplier` (`requests/approver.rb`), while cancellation rewrites payroll
  line items inside Workforce (`Requests::Canceller#rollback_permission`). Deferred: advances (SEC-M2-7 product
  decision, eligibility baseline noise), punch correction (high risk, after this pilot), the Inventory & Purchasing ↔
  Finance & Sales settlement (~1,067 lines, money, two-way: `FinancialSettlement` names `GoodsReceipt` /
  `PurchaseRequestAdvance` constants), the laundry labour-cost report (ready, but no cycle), POS terminals / warehouse
  access (low value). `PurchaseRequestAdvance` is missing from `module-boundaries.md` §10 (Inventory & Purchasing in
  practice).
* **Security unblock (both fixed before M1):**

| ID | Severity | Finding | Fix | Commit |
|---|---|---|---|---|
| SEC-P9-1 | Medium | `EmployeeRequestPolicy#approve?` / `#reject?` / `#cancel?` ignored the configured `approve_requests` scope (requests are found through the broader `view_requests` scope) | The requester must be inside `EmployeeScope#for_permissions(:approve_requests, :view_requests, :view_employees)` (as `create?`); approvers may still cancel their own approved request | `09957e9` |
| (follow-up, product decision) | Medium | A `pay_advances` holder could cancel ANY request type business-wide, ignoring the `pay_advances` scope, and bypass the `approve_requests` scope | `pay_advances` cancels `salary_advance?` requests only, own or inside `for_permissions(:pay_advances, :view_requests, :view_employees)` | `0512fc6` |

Regression specs: `spec/requests/security/employee_request_approve_scope_spec.rb` (13; 5 fail on the old code),
`employee_request_pay_advances_cancel_spec.rb` (17; 10 fail on `09957e9`).

### 24.2 M1 — characterization

`spec/characterization/workforce/request_permission_payroll_effects_spec.rb` (53 examples: 26 per permission type via
shared definitions, plus one request-level policy check), complementing `permission_applier_spec`, `canceller_spec`,
`approver_spec` and the security specs. Fixture: one attendance record carrying both a 40-minute late arrival (rule
> 15 min → 25 % of the 400 daily rate = −100) and a 120-minute early leave (> 30 min → 50 % = −200), each with its
penalty line. Disabling the applier or the rollback fails 14 examples each.

**Observed behaviour (pinned):**

| Area | Current behaviour |
|---|---|
| Approval flow | `Requests::Approver#approve_standard`: `request.update!(approved)` → `Payroll::PermissionApplier.call(request)` → `log_audit("approve")`, **no surrounding transaction** |
| Approval effect | Only an EXISTING `late_penalty` / `early_leave_penalty` line of the attendance record (`source_type: "AttendanceRecord"`) in an OPEN period (`period_month` / `period_year` of the work date, not finalized / paid) of an existing entry is changed: effective = `original_minutes` (else attendance minutes) − approved minutes; amount re-derived with `Salary::DailyRateCalculator` + `Attendance::PenaltyCalculator`; zero → line destroyed, else updated (`original_minutes`, `permission_minutes`); `entry.recalculate_totals!` (flags `needs_review`). Over the threshold the amount is unchanged (flat rule) but the minutes are recorded |
| Approval no-ops | Finalized / paid period, no period, no entry, no attendance record, no matching line → request approved, payroll untouched; never creates an entry or line |
| Same-day re-approval | A second approved permission replaces the first (recomputed from `original_minutes` − the new minutes), not cumulative |
| Other line | A late permission never touches the early-leave line of the same record, and vice versa |
| Audit | Request audit only (`approve`, `cancel`); no `AuditLog` / `PayrollAuditLog` row for the line change |
| Approval failure | An applier error is not rescued: the request is already approved (committed), no `approve` audit, payroll unchanged, the error propagates (500) |
| Cancellation flow | `Requests::Canceller#cancel`: one transaction — `rollback_permission` → `request.update!(cancelled)` → `log_audit("cancel")`; a rollback error result → `ActiveRecord::Rollback`, request stays approved |
| Rollback effect | Re-derives the FULL penalty from the CURRENT attendance minutes (not the line's `original_minutes`): line updated (`permission_minutes: nil`), recreated (description "Late arrival / Early leave <date>") if destroyed, or destroyed if now zero; `recalculate_totals!`; attendance record untouched |
| Rollback refusal | Covering period (any status, by request month) finalized / paid → `requests.errors.cannot_cancel_finalized`, request approved, payroll and audit unchanged |
| Rollback no-ops | No attendance record, no period, no entry, zero raw minutes → cancelled, payroll untouched |
| Rollback failure | An exception is not rescued, but the transaction rolls back: request approved, no `cancel` audit |
| Generation | `Payroll::EntryCalculator` subtracts `EmployeeRequest.approved_minutes` (first approved, `affects_payroll`) when the entry is generated after approval; cancelling then restores the full penalty |
| Policy | The effect path is behind `EmployeeRequestPolicy` (an out-of-scope approver cannot trigger it) |

**Shared helpers:** `rollback_permission` uses `covering_period`, `daily_rate_for` (`Salary::DailyRateCalculator`) and
`compute_penalty` (`Attendance::PenaltyCalculator`), which `rollback_punch_correction` / `rollback_punch_payroll` also
use — punch correction stays out of scope; the helpers must keep serving it.

**Direct Workforce → Attendance & Payroll references in this flow:** `requests/approver.rb` → `Payroll::PermissionApplier`;
`requests/canceller.rb#rollback_permission` → `AttendanceRecord`, `PayrollPeriod`, `PayrollEntry`, `PayrollLineItem`
(find / create / update / destroy), `entry.recalculate_totals!`, `Salary::DailyRateCalculator`,
`Attendance::PenaltyCalculator`.

**Risky / surprising (pinned, not changed):** approval is not atomic with its payroll effect; apply uses the line's
`original_minutes` but rollback the current attendance minutes (an attendance edit between them changes the restored
amount); re-approval replaces rather than accumulates while generation counts only the first approved request;
`affects_payroll` gates generation but not apply / rollback (always true for these types today).

### 24.3 Verification (M1, seed 20261006)

| Run | Result |
|---|---|
| M1 characterization, seeds 20261006 / 12345 / 98765 | 53 / 0 under each |
| Permission-effects core | 177 / 0 |
| Request-area set (`workforce-request-permission-baseline-failures.txt`) | 1622 examples, **the same 27 baseline IDs** (1569 + 53) |
| `spec/architecture` + `spec/requests/security` | 545 / 0 |
| Request policy + Pilot 9 security specs | 67 / 0 |

`zeitwerk:check`, RuboCop and `git diff --check` clean.

### 24.4 Migration path (M1 evidence)

* **M2 NEEDED:** a Workforce-defined contract for the payroll effect of a permission request — applied on approval,
  reverted on cancellation (returning a refusal for a locked period, inside the cancel transaction) — implemented by
  Attendance & Payroll.
* **M3 NEEDED:** route `approve_standard` and `rollback_permission` through it.
* **M4 NEEDED:** the revert logic (`rollback_permission` and its use of the shared helpers) moves into Attendance &
  Payroll; the punch-correction rollback keeps its own copy until its own pilot.
* **M6 NEEDED**; **M7** likely not needed (no model moves in scope); **M8 NEEDED.**

### 24.5 M2 — Workforce contract `Requests::PermissionPayrollEffects`

**Owner: Workforce.** The request and its lifecycle (approve, cancel) are Workforce's; the payroll it affects is
Attendance & Payroll's. Named in Workforce's request namespace (`app/services/requests/`, next to `Approver` /
`Canceller`), as Pilot 4 (`Shifts::PenaltyRuleSettings`) and Pilot 8 (`Employee::InsuranceProfileEffects`) named theirs
after their callers' namespace.

| | |
|---|---|
| `permission_approved(request:)` | `request`: the just-approved `EmployeeRequest`. Brings the payroll in line with the approved minutes, or does nothing (not a permission; no open period, entry, attendance record or penalty line). **No refusal** — approval is never blocked by payroll, as today. Returns `nil` |
| `permission_cancelled(request:)` | Called inside the cancel transaction. Returns a `Symbol` in `CANCEL_RESULTS = %i[reverted refused]`: `:reverted` — reverted, or nothing to revert; `:refused` — the affected payroll is locked (finalized / paid), the caller keeps the request approved. Any other value raises `ArgumentError`, so no payroll record crosses the contract. Unexpected failures raise (normal refusal is not an exception) |
| No `actor` | Neither `PermissionApplier` nor `rollback_permission` uses one; the caller writes the `approve` / `cancel` audit. Not added for symmetry |
| Registration | `register` rejects a handler missing an operation; no handler → `NotRegistered` (a `StandardError`). Wired in `config/initializers/request_permission_payroll_effects.rb` (`to_prepare`) |
| Implementation (Attendance & Payroll) | `Payroll::PermissionPayrollEffects`: `permission_approved` → `Payroll::PermissionApplier.call(request)`; `permission_cancelled` → delegates to `Requests::Canceller.revert_permission_payroll(request)` (below) |

**Why no Attendance & Payroll model is exposed:** Workforce needs only a decision (applied / reverted / refused), not
payroll state. Periods, entries, lines, attendance records and the two calculators stay behind the implementation; the
contract source names none of them (asserted).

**Design issue — temporary reverse delegation (Pilot 3 M2 precedent).** The revert logic is still the private
`Requests::Canceller#rollback_permission` (Workforce) until M4. So that the Attendance & Payroll implementation exists
without moving code, `Requests::Canceller` gained a behaviour-neutral public seam, `revert_permission_payroll(request)`:
it runs the unchanged `rollback_permission` and maps its result — success → `:reverted`; the
`requests.errors.cannot_cancel_finalized` error → `:refused`; any other error (an invalid penalty line, today returned as
`err(messages)`) → raises `Requests::Canceller::PermissionRevertFailed` with the messages. Nothing is cancelled or audited
there; `Requests::Canceller#cancel` still calls `rollback_permission` directly. Consequence for sequencing: routing the
canceller (M3) before M4 would make Workforce call Attendance & Payroll which calls back into Workforce — M3 should
route the approver and, for the canceller, land together with M4 (or M4 first), and map `PermissionRevertFailed` back to
the current `err(messages)` result.

**Shared helpers (for M4):** `covering_period`, `daily_rate_for` (`Salary::DailyRateCalculator`) and `compute_penalty`
(`Attendance::PenaltyCalculator`) serve both `rollback_permission` and the punch-correction rollback; M4 must leave the
punch-correction copy working (out of scope). The contract exposes none of them.

**Callers not changed:** `Requests::Approver#approve_standard` still calls `Payroll::PermissionApplier` directly;
`Requests::Canceller#rollback_approval_effects` still calls `rollback_permission`.

**Spec:** `spec/services/requests/permission_payroll_effects_spec.rb` (15) — registration (implementation registered,
incomplete handler rejected, `NotRegistered`), dispatch (request passed unchanged, approval returns `nil`, cancellation
returns `:reverted` / `:refused` only, payroll records / strings / booleans / `nil` rejected, errors propagate), the
implementation (approval = `PermissionApplier`, no-op for a locked period or an advance; cancellation `:reverted` and
restored for an open period without cancelling or auditing the request, `:refused` for finalized / paid, `:reverted` with
nothing to revert, `PermissionRevertFailed` for any other failure), no Attendance & Payroll names in the contract.

**Verification (seeds 20261006 / 12345 / 98765, identical):** contract + M1 68 / 0 (15 + 53); permission-effects core
+ contract 192 / 0 (177 + 15); `spec/architecture` + `spec/requests/security` 545 / 0; request-area set (seed
20261006) 1622 examples with the same 27 baseline IDs; Pilot 9 security + policy specs 67 / 0. `zeitwerk:check`,
RuboCop and `git diff --check` clean.

### 24.6 M3-A — approval routed through the contract (cancellation deliberately not)

| Caller | Before | After |
|---|---|---|
| `Requests::Approver#approve_standard` | `Payroll::PermissionApplier.call(@request)` | `Requests::PermissionPayrollEffects.permission_approved(request: @request)` — same place: after `@request.update!(approved)`, before `log_audit("approve")`, no transaction |

The registered implementation (`Payroll::PermissionPayrollEffects`) runs `Payroll::PermissionApplier` with the same
request, so every M1 example is unchanged. Salary-advance approvals take the same `approve_standard` path and call the
contract (a no-op there, as before); punch-correction approval (`approve_punch_correction`) and rejection never call
it. `Requests::Approver` no longer names `Payroll::PermissionApplier` (it still creates `Advance` in `pay` — the
advances edge, outside this pilot).

**Cancellation is intentionally NOT routed (M3-B lands with M4).** `Requests::Canceller#cancel` /
`#rollback_permission` are unchanged and never call `permission_cancelled`. Routing them now would make Workforce call
Attendance & Payroll (`Payroll::PermissionPayrollEffects#permission_cancelled`), which still delegates back to
Workforce (`Requests::Canceller.revert_permission_payroll`, the M2 seam) — a temporary cycle. M4 moves the revert into
Attendance & Payroll; M3-B then routes the canceller (mapping `PermissionRevertFailed` to today's `err(messages)`) and
removes the seam. The seam stays in place, unused by the normal cancellation flow.

**Specs:** `spec/services/requests/permission_payroll_effects_routing_spec.rb` (7) — for both permission types the
contract is called once with the same request, after the approval is saved and before the audit, and
`PermissionApplier` is not called directly; the registered implementation still runs `PermissionApplier` with the
request; a contract error propagates (request approved, no audit); advance approval calls it, punch-correction approval
and rejection do not; cancellation does not call the contract. `spec/architecture/workforce_request_permission_payroll_boundary_spec.rb`
(4) — the approver names neither `PermissionApplier` nor the implementation and calls `permission_approved` exactly
once; the contract names nothing from Attendance & Payroll while the implementation keeps its applier; a planted probe
is caught. 6 of the 11 fail on the pre-M3 approver.

**Verification (seeds 20261006 / 12345 / 98765, identical):** routing + boundary 11 / 0; M1 53 / 0; contract + M1
68 / 0; permission-effects core 199 / 0 (192 + 7); `spec/architecture` + `spec/requests/security` 549 / 0 (545 + 4);
Pilot 9 security + policy 67 / 0; request-area set (seed 20261006) 1622 examples with the same 27 baseline IDs.
`zeitwerk:check` and `git diff --check` clean; RuboCop clean on the new specs (the 8 `Layout/SpaceInsideArrayLiteralBrackets`
offenses in `approver.rb` pre-date M3 and are on untouched lines — left as is).

### 24.7 M3-B + M4 — cancellation routed, revert moved into Attendance & Payroll

Landed together so there is never a Workforce → Attendance & Payroll → Workforce loop. The boundary is now one-way:

```
Workforce  Requests::Approver#approve_standard ─┐
           Requests::Canceller#cancel ──────────┤ Requests::PermissionPayrollEffects (WF contract)
                                                ▼
A&P        Payroll::PermissionPayrollEffects ── permission_approved  → Payroll::PermissionApplier
                                             └─ permission_cancelled → Payroll::PermissionReverter (new)
```

| Change | Detail |
|---|---|
| **New `app/services/payroll/permission_reverter.rb`** | `Payroll::PermissionReverter.call(request)` — line-for-line port of `Requests::Canceller#rollback_permission`: attendance record → covering period (any status, by request month) → `:refused` if finalized / paid → entry → raw minutes (CURRENT attendance) → full penalty via `Salary::DailyRateCalculator` + `Attendance::PenaltyCalculator` → line updated (`permission_minutes: nil`) / recreated ("Late arrival / Early leave <date>") / destroyed (zero) → `recalculate_totals!` → `:reverted`. No-ops (not a permission, no attendance, no period, no entry, zero minutes) → `:reverted`. No rescue: an invalid line raises `ActiveRecord::RecordInvalid`. Never writes attendance |
| `Payroll::PermissionPayrollEffects#permission_cancelled` | `Payroll::PermissionReverter.call(request)` (was: delegation to `Requests::Canceller.revert_permission_payroll`). Calls nothing in Workforce |
| `Requests::Canceller#rollback_approval_effects` | late / early leave → `revert_permission_payroll_effect`: `Requests::PermissionPayrollEffects.permission_cancelled(request: @request)` at the same point, inside the same cancel transaction; `:refused` → `err(I18n.t("requests.errors.cannot_cancel_finalized"))` (the existing result: rollback, request stays approved, no cancel audit), `:reverted` → `ok` |
| **Removed from `Requests::Canceller`** | `rollback_permission`, the M2 bridge `self.revert_permission_payroll` / `#revert_permission_payroll`, `PermissionRevertFailed`, the error-text matching |

**Result semantics unchanged:** only the locked-period condition maps to `:refused`. An invalid penalty line used to be
rescued inside `rollback_permission` and returned as `err(messages)`; it now raises out of the reverter, the cancel
transaction rolls back, and `Requests::Canceller#cancel`'s existing `rescue ActiveRecord::RecordInvalid` returns the same
`err(messages)` — identical result for the caller. Any other error propagates, as before.

**Shared helpers — decision: duplicate, do not move.** `covering_period`, `daily_rate_for` and `compute_penalty` are
also used by the punch-correction rollback (`rollback_punch_correction`, `rollback_punch_payroll`,
`restore_penalty_line_item`), so they stay in `Requests::Canceller` unchanged, now serving punch correction only. The
reverter has its own private copies (~25 lines). Moving them to a shared Attendance & Payroll owner would have required
touching punch correction; leaving the reverter calling the Workforce copies would have created Attendance & Payroll →
Workforce. **Debt:** the duplication goes when the punch-correction pilot moves its rollback to Attendance & Payroll.

**Boundary note.** `Requests::Canceller` still names Attendance & Payroll (`AttendanceRecord`, `PayrollPeriod`,
`PayrollEntry`, `Salary::` / `Attendance::` calculators, `Attendance::RecordRecomputer`) — but only in the
punch-correction rollback (§14.2 #3, out of this pilot). The boundary spec pins that: such references are allowed only
inside the six punch-correction methods.

**Specs:** new `spec/services/payroll/permission_reverter_spec.rb` (16: open → restored `:reverted`; finalized / paid
`:refused` and untouched; no period / no entry / no attendance `:reverted`; early-leave line restored, late line
untouched; deleted line recreated; zero penalty deletes; zero minutes no-op; totals recalculated; current attendance
minutes; attendance never written; RecordInvalid propagates; non-permission no-op; the contract passes the same
request). Routing spec (12, was 7): cancellation calls the contract once with the same request inside the transaction
before the status change, for both types; `:refused` → `cannot_cancel_finalized`, request approved, no audit;
RecordInvalid → same failed result; unexpected error → rollback; pending / advance / punch cancellations never call it.
Contract spec: the bridge example replaced (any other failure raises, never `:refused`). Boundary spec (13, was 4):
no permission internals in either caller; canceller's Attendance & Payroll names only inside punch-correction methods;
approver names no payroll model; each caller calls its operation once; the implementation may use its own models but
never `Requests::` / lifecycle calls / status writes; bridge and `rollback_permission` gone (source + reflection);
punch-correction methods present; planted probes. Pilot 4 penalty-rule boundary: `permission_reverter.rb` added to its
Attendance & Payroll allow-list (it names `Attendance::PenaltyCalculator`), the canceller's reason narrowed to the punch
rollback. Against the pre-M4 canceller / implementation the new examples fail 11 of 41.

**Verification (seeds 20261006 / 12345 / 98765, identical):** reverter + routing + contract + boundary 56 / 0; M1 53 / 0
(unchanged); permission-effects core 220 / 0; punch-correction specs (19 files) 407 examples, 1 failure — the documented
baseline `employee_request_spec.rb:432`; `spec/architecture` + `spec/requests/security` 558 / 0 (549 + 9); Pilot 9
security + policy 67 / 0; request-area set (seed 20261006) 1622 examples with the same 27 baseline IDs. `zeitwerk:check`,
RuboCop (8 changed files) and `git diff --check` clean.

### 24.8 M6 — the permission payroll boundary, enforced

`spec/architecture/workforce_request_permission_payroll_boundary_spec.rb` (24 examples, was 13; the source-scanning
style of the earlier boundary specs, full-line comments ignored):

| Rule | Enforced |
|---|---|
| Permission path | `Requests::Approver#approve_standard` and `Requests::Canceller#cancel`, `#rollback_approval_effects`, `#revert_permission_payroll_effect` (method-level) name nothing from Attendance & Payroll: no `Payroll::PermissionApplier` / `PermissionReverter` / `PermissionPayrollEffects`, `PayrollPeriod`, `PayrollEntry`, `PayrollLineItem`, `AttendanceRecord`, `Attendance::PenaltyCalculator`, `Salary::DailyRateCalculator`, `Attendance::RecordRecomputer`, or any other `Payroll::` / `Attendance::` / `Salary::` constant; the methods must still exist |
| Callers | neither caller names the applier, reverter or implementation anywhere; the approver names no payroll model; each calls the contract exactly once (`permission_approved` / `permission_cancelled`) |
| **Punch-correction exception** | `Requests::Canceller` may name Attendance & Payroll ONLY inside `rollback_punch_correction`, `rollback_punch_payroll`, `restore_penalty_line_item`, `covering_period`, `daily_rate_for`, `compute_penalty` (the legacy punch-correction rollback, §14.2 #3); anywhere else in the class fails. The exception is per method, not per class, and the methods must still exist |
| A&P → Workforce | `payroll/permission_payroll_effects.rb`, `permission_reverter.rb`, `permission_applier.rb`: no `Requests::`, no `EmployeeRequest` constant, no `approve` / `reject` / `cancel` / `pay` call, no `update!(status: …)` or `status =` — they only read the request they are handed |
| Contract | `Requests::PermissionPayrollEffects` names no `Payroll` / `Attendance::` / `Salary::` and no payroll or attendance model |
| Naming | `Requests::PermissionPayrollEffects` only in the two callers, the contract and the composition root; `Payroll::PermissionPayrollEffects` only in itself and the composition root; the applier and the reverter only in the implementation |
| Removed | the M2 bridge (`revert_permission_payroll`, `PermissionRevertFailed`) and `rollback_permission` stay gone (source + reflection) |

**Probes.** In-spec (stubbed reads): the eight M6 probes — `PermissionApplier` in the approver, `PermissionReverter` in
the canceller, `PayrollPeriod` / `PayrollLineItem` / `AttendanceRecord` in the canceller's permission method, the
implementation naming `Requests::Canceller`, the reverter mutating the request (`update!(status:)`, `status =`,
`EmployeeRequest`), the contract naming `Payroll::` — each caught; a payroll reference inside the punch-correction
rollback is not a violation. **Physical probes** (temporary, restored with `git checkout`): the applier added to
`approve_standard`, `PayrollLineItem` to the canceller's permission method, `Requests::Canceller` to the implementation,
`PayrollPeriod` to the contract — 6 rule examples failed, each naming its line; after restore 24 / 0.

**Repository scan (app / lib / config):** the three permission classes appear only where allowed — the callers use the
contract (`approver.rb:171`, `canceller.rb:100`), the implementation names the applier and the reverter, the
composition root wires it. In Workforce request code the remaining Attendance & Payroll names are: `canceller.rb` ×9
(all inside the punch-correction methods — allowed legacy), `punch_correction_applier.rb` ×2 and
`punch_correction_assessment.rb` ×2 (the punch-correction services — legacy, §14.2 #3), `employee_requests_controller.rb`
:78 / :320 (punch-correction attendance reads — legacy read edge), `views/employee_requests/_resulting_duration.html.erb`
:3 (inside an ERB comment — documentation). The general payroll models (`PayrollPeriod` 51 files, `PayrollEntry` 32,
`PayrollLineItem` 27, `AttendanceRecord` 40) are otherwise Attendance & Payroll's own code, Reporting reads and other
documented edges outside this pilot. **No unexpected violation.**

**Final boundary.** Workforce reaches the payroll effect of late / early-leave permissions only through its own
contract; Attendance & Payroll implements it and never calls Workforce request services or lifecycle methods. No
reverse dependency; no direct Workforce → Attendance & Payroll implementation dependency in the permission path.
**Remaining debt:** the punch-correction rollback in `Requests::Canceller` (and its helpers, duplicated by
`Payroll::PermissionReverter`) — for a future punch-correction pilot. `module-boundaries.md` §12.2 (WF → AP row) and
§14.2 #4 record the resolved permission half.

**Verification (seeds 20261006 / 12345 / 98765, identical):** boundary 24 / 0; routing + contract + reverter 43 / 0;
M1 53 / 0; permission-effects core 220 / 0; `spec/architecture` + `spec/requests/security` 569 / 0 (558 + 11); Pilot 9
security + policy 67 / 0; punch-correction specs 418 examples (the 407 punch examples + the 11 new boundary examples,
whose file mentions punch correction), 1 failure — the documented `employee_request_spec.rb:432`; `spec/services/payroll`
558 / 0; request-area set (seed 20261006) 1622 examples with the same 27 baseline IDs. `zeitwerk:check`, RuboCop and
`git diff --check` clean.

### 24.9 M8 — close-out — Pilot 9 COMPLETE

**Scope:** the payroll effect of Workforce late-permission and early-leave requests (approval and cancellation).
**Not included:** punch correction, advances, `pay_advances` authorization beyond the unblock decision, salary
configuration, other payroll flows.

| Step | Result |
|---|---|
| M0 | COMPLETE — candidate selection, dependency map, SEC-P9-1 found → NOT READY (§24.1) |
| Security unblock | COMPLETE — SEC-P9-1 `09957e9` (approve / reject / cancel respect the `approve_requests` scope); `0512fc6` (product decision: `pay_advances` cancels `salary_advance?` requests only, within its own scope) |
| M1 | COMPLETE — `c0cd7ff`, 53 characterization examples (§24.2) |
| M2 | COMPLETE — `27fe23a`, Workforce contract `Requests::PermissionPayrollEffects` (§24.5) |
| M3-A | COMPLETE — `2d55172`, approval routed through the contract (§24.6) |
| M3-B + M4 | COMPLETE — `2663590`, cancellation routed and the revert moved into `Payroll::PermissionReverter`; temporary M2 bridge removed (§24.7) |
| M6 | COMPLETE — `cc8fe42`, boundary spec (24 examples) (§24.8) |
| M7 | NOT NEEDED — no model move in scope (`EmployeeRequest` stays where it is) |
| M8 | COMPLETE — this close-out |

**Final ownership.** Workforce owns the `EmployeeRequest` lifecycle (approve, reject, cancel, status, audit, the cancel
transaction) and the contract `Requests::PermissionPayrollEffects`. Attendance & Payroll owns the payroll effect —
period lookup, the finalized / paid check, the entry and penalty line, the penalty calculation, the totals —
implemented by `Payroll::PermissionPayrollEffects` with `Payroll::PermissionApplier` (approval) and
`Payroll::PermissionReverter` (cancellation), registered in `config/initializers/request_permission_payroll_effects.rb`.

**Final dependency direction (one-way):**

```
Requests::Approver#approve_standard ─┐
Requests::Canceller#cancel ──────────┴─▶ Requests::PermissionPayrollEffects (WF contract)
                                              │
                                              ▼
                     Payroll::PermissionPayrollEffects ─▶ PermissionApplier  (permission_approved  → nil)
                                                        └▶ PermissionReverter (permission_cancelled → :reverted | :refused)
```

Attendance & Payroll never calls Workforce request services or lifecycle methods; the permission path names nothing
from Attendance & Payroll (enforced). Locked period: `:refused` — only for a finalized / paid covering period — keeps the
request approved with the existing `cannot_cancel_finalized` result, no cancel audit; any other failure raises (an
invalid line ends in the same `err(messages)` through `#cancel`'s existing `RecordInvalid` rescue).

**Legacy exception (out of scope):** `Requests::Canceller` keeps the punch-correction rollback, which names Attendance
& Payroll inside six methods only — `rollback_punch_correction`, `rollback_punch_payroll`, `restore_penalty_line_item`,
`covering_period`, `daily_rate_for`, `compute_penalty`; any such reference elsewhere in the class fails the boundary.

**Remaining debt (not solved here):**

1. The punch-correction rollback remains in Workforce (`Requests::Canceller`) — `module-boundaries.md` §14.2 #3 and the
   punch half of #4.
2. `Payroll::PermissionReverter` carries small private copies of `covering_period`, `daily_rate_for` and
   `compute_penalty` (the canceller's copies serve punch correction).
3. Resolve the duplication when the punch-correction pilot moves its rollback into Attendance & Payroll.
4. Recorded M1 observations, unchanged: approval is not atomic with its payroll effect; approval uses the line's
   `original_minutes` while cancellation uses the current attendance minutes; a same-day re-approval replaces rather
   than accumulates; `affects_payroll` gates generation only (always true for these types).

**Final verification (on `cc8fe42`, seeds 20261006 / 12345 / 98765, identical):**

| Run | Result |
|---|---|
| M1 characterization | 53 / 0 |
| Contract + routing + reverter | 43 / 0 |
| M6 boundary | 24 / 0 |
| Permission-effects core | 220 / 0 |
| `spec/architecture` + `spec/requests/security` | 569 / 0 |
| Pilot 9 security + policy (SEC-P9-1, `pay_advances`, request policy) | 67 / 0 |
| Request-area set (`workforce-request-permission-baseline-failures.txt`) | 1622 examples, 27 failures — **the same 27 IDs as at M0**, compared by exact ID under each seed |
| Punch-correction specs (the 17 pre-existing files that mention punch correction) | 382 examples, 1 failure — `employee_request_spec.rb:432` (documented baseline); identical at `2d55172` (before M4) and at `cc8fe42` |

The earlier "407" / "418" punch-correction figures counted Pilot 9's own specs that mention punch correction (the
boundary spec, 13 then 24 examples, and the routing spec); excluding them the punch-correction specs are 382 examples,
unchanged by Pilot 9. `zeitwerk:check`, RuboCop (every Ruby file Pilot 9 changed, 32) and `git diff --check` clean.
`module-boundaries.md`: status header, §12.1 inversion table, §12.2 WF → AP row and §14.2 #4 represent the final state.

**Pilot 9 (Workforce — Request Permission Payroll Effects) is COMPLETE.** Nothing pushed or merged.

## 25. Pilot 10 — Punch Correction payroll / attendance effects

**Status: M2 COMPLETE** (on `feature/pilot-10-punch-correction`: M1 `5c8729e`, M2 "refactor: define punch
correction effects contract"). M0 and the unblock are merged (`66abcf5`, PR #34 → `fix/pilot-9-request-scope`, PR #33
→ `main` `82cce16`). Contract defined; no caller routed, no code moved; M3 – M8 not started.

### 25.1 M0 — findings (read-only)

* **What punch correction does.** Approve (`Requests::Approver#approve_punch_correction`, one transaction): request →
  approved + `approved_punch_at` → `Requests::PunchCorrectionApplier` (Workforce) snapshots the record's punches onto the
  request (`original_*`), sets the corrected punch (`admin_manual`), saves, `Attendance::RecordRecomputer`, saves, then
  `Payroll::PunchCorrectionApplier` (open period only) updates / deletes the EXISTING late / early-leave lines and
  recalculates totals — it never creates a line; the approve audit (with attendance metadata) after commit. Cancel
  (`Requests::Canceller`, one transaction): `rollback_punch_correction` (refused without a record or for a finalized /
  paid period) restores the snapshot and recomputes, `rollback_punch_payroll` updates / RECREATES / deletes the lines.
  `Requests::PunchCorrectionAssessment` reads the attendance window, record, a projected recompute and duration check.
* **Ownership today.** Workforce owns the request lifecycle — and also performs the Attendance & Payroll writes
  (attendance mutation in `Requests::PunchCorrectionApplier`; attendance + payroll restore in the canceller's six punch
  methods). Attendance & Payroll owns `Payroll::PunchCorrectionApplier`, the attendance services and payroll models. No
  code-level A&P → Workforce dependency; the snapshot is attendance data stored on the Workforce request table.
* **Risks recorded.** Approval adjusts only existing penalty lines (no line creation; worked / overtime / absence not
  re-derived — every other attendance mutation uses `Payroll::EntryRecalculator`); apply never creates lines while the
  revert does; no record → approval refused (unlike permissions); the shared helpers duplicated with Pilot 9's
  `Payroll::PermissionReverter`.
* **SEC-M2-2:** fixed in `ca66c43` (not reproduced). Its follow-up (attendance edits use the `view_attendance` lookup scope
  and allow editing one's own record) is still an open product decision on a different path — not in the punch flow.
* **Blockers found:** SEC-P10-1 and the locked-period approval gap (below).

### 25.2 Unblock — product decisions applied

| Item | Finding | Resolution |
|---|---|---|
| **SEC-P10-1** (Medium) | An approver could create a request on behalf of an employee and approve it themselves: `Approvals::SelfApproval` compared the approver only with `user_id`, requests recorded no submitter, and creation was not audited (reproduced: a punch correction rewrote attendance; the audit showed only `approve` by the same actor) | New nullable `employee_requests.submitted_by_id` (FK → users, indexed; migration `20261008100000`). `Requests::Submitter` (new) is the single creation path for web and API: sets `submitted_by` to the signed-in user (never from params), saves and writes a `create` audit (`request_type`, `for_user_id`, `submitted_by_id`, `on_behalf`) in one transaction. `EmployeeRequestPolicy#approve?` / `#reject?` and `Requests::Approver#self_approval?` refuse the employee **and** the submitter |
| Locked-period approval (product decision) | Approving a punch correction in a finalized / paid period rewrote attendance while payroll stayed frozen, and the cancel was then refused — a permanent mismatch | `Requests::PunchCorrectionApplier` refuses (`requests.errors.cannot_approve_finalized`, en + ar) when the request month's payroll period is `locked?` (finalized or paid), after the existing missing-record check and before any write; it runs inside the approver's existing transaction, which rolls the approval back — request pending, no `approved_punch_at`, no snapshot, attendance / payroll untouched, no approve audit |

**Submitter data.** `user_id` = whom the request is for; `submitted_by_id` = who created it (equal for self-requests).
Existing rows stay NULL — creation was never audited, so there is no reliable source to backfill from — and are read as
"submitter unknown": the self-approval rule keeps its previous, employee-only meaning for them. New rows always get a
submitter (`Requests::Submitter`; the model defaults it to the employee for any other creation path, e.g. seeds).
**Residual:** a legacy PENDING request created on behalf of someone may still be approved by its (unrecorded) creator;
it disappears as those requests are decided. **Migration run on the TEST database only** — run `bin/rails db:migrate` on
development / production as part of deployment.

**Atomicity preserved:** no new transaction; the guard is the first step of the applier inside the approver's
transaction; the approve audit is still written only after commit. Permissions (Pilot 9) are unaffected by the guard.

**Specs:** `spec/requests/security/employee_request_submitter_spec.rb` (11 — submitter and audit for self / on-behalf /
API, mass assignment ignored, employee cannot self-approve, submitter cannot approve or reject (web + service), another
approver can, legacy NULL rule, branch scope, cross-business 404; the 2 on-behalf self-approval examples fail on the old
authorization). `spec/requests/security/punch_correction_locked_period_spec.rb` (10 — finalized / paid refused with the
error, every state unchanged, web alert; open period and no period unchanged; missing record message first; permissions
unaffected; the 6 locked examples fail without the guard).

**Verification (seeds 20261006 / 12345 / 98765, identical):** SEC-P10-1 11 / 0; locked period 10 / 0; punch-correction
specs (17 files) 382 / 1 — the documented `employee_request_spec.rb:432`; request security + policy 124 / 0; Pilot 9
M1 + contract + routing + reverter + boundary 120 / 0; Pilot 9 core 220 / 0; `spec/architecture` + `spec/requests/security`
590 / 0 (569 + 21); request-area set 1622 examples with the same 27 baseline IDs. M0 re-check: SEC-P10-1 not reproduced
(on-behalf creation records the approver; the same approver's approval is refused; attendance untouched); locked-period
approval blocked. `zeitwerk:check`, RuboCop (new / fully changed files clean; the controller and approver keep their
pre-existing 4 / 8 layout offenses on untouched lines) and `git diff --check` clean.

### 25.3 M1 — characterization

**Scope.** The attendance and payroll effects of approving and cancelling a punch correction — what the future
Workforce → Attendance & Payroll contract will carry. Request creation, identity, the reviewer's date / time, the
attendance window, duration severity, punch order, self-approval, scope and the locked-period rule are already pinned
by dedicated specs and are reused, not duplicated:

| Area | Pinned by |
|---|---|
| A. creation, `submitted_by_id`, create audit, legacy NULL, scope | `spec/requests/security/employee_request_submitter_spec.rb` (11); SEC-P9-1 specs |
| B. field updates, snapshot, recompute, reviewer date / time, overnight | `spec/services/requests/punch_correction_applier_spec.rb`, `spec/requests/employee_request_reviewer_datetime_spec.rb`, `employee_request_review_changes_spec.rb` |
| C. window, confirmation, duration severity, punch order, missing record, self-approval | `punch_correction_window_guard_spec.rb`, `employee_request_attendance_window_spec.rb`, `employee_request_resulting_duration_spec.rb`, `employee_request_check_out_order_spec.rb`, `approver_spec.rb`, `employee_request_reviewer_visibility_spec.rb` |
| D. finalized / paid refused (all state unchanged), no period | `spec/requests/security/punch_correction_locked_period_spec.rb` (10) |

New: `spec/characterization/workforce/punch_correction_effects_spec.rb` (29 examples; disabling the approval payroll
effect fails 12, disabling the cancellation payroll restore fails 6).

**E. Approval — `Payroll::PunchCorrectionApplier` (open period of the record's work date, existing entry):**
* Only EXISTING late / early-leave lines of the attendance record change: amount recomputed from the record's new
  minutes (`Salary::DailyRateCalculator` + `Attendance::PenaltyCalculator`), `original_minutes` = new minutes, deleted
  when the new minutes or penalty are 0; then `recalculate_totals!` (flags `needs_review` only when totals change).
* A correction that INTRODUCES lateness creates no line (payroll unchanged). No entry → nothing created.
* Worked days / overtime / absence are not re-derived (e.g. completing an incomplete day leaves `days_worked`).
* An approved permission already applied to the line is IGNORED: the amount is recomputed from the full new minutes
  (`permission_minutes` kept but not subtracted) — unlike `Payroll::PermissionApplier`.

**F. Approval atomicity.** One transaction: request approved + `approved_punch_at`, snapshot, punch, recompute, payroll.
A failure in the payroll effect or the record recompute rolls everything back (request pending, no `approved_punch_at`,
no snapshot, attendance and payroll unchanged, no audit); `Requests::PunchCorrectionApplier` returns the exception's
message as the error. The approve audit is written after commit (the payroll effect runs before it exists); an audit
write failure is swallowed (`log_audit`) — the approval and its effects stay, without an audit row. The pre-approval
assessment recomputes an unsaved copy outside the transaction.

**G. Cancellation (`Requests::Canceller`, one transaction).** Restores the punch and its source from the request's
snapshot and recomputes; then for BOTH line types updates the line to the restored minutes, RECREATES a missing line
(description "Late arrival / Early leave <date>"), or deletes it when the restored minutes or penalty are 0; totals;
cancelled; `cancel` audit (`changes: {status: [approved, cancelled]}`, `metadata: {reason, request_type}`). Finalized /
paid → `cannot_cancel_finalized` (attendance stays corrected, payroll untouched, no audit); no record →
`no_attendance_record`; no entry / no period → attendance restored, cancelled. A payroll-restore exception is not
rescued but rolls the cancel back (attendance not restored, no audit).

**Asymmetries (pinned, not fixed):** approval never creates a penalty line, cancellation does; approval looks up only
OPEN periods by the record's work date (`open_period_covering`), cancellation the request month's period in ANY status
(`covering_period`) and refuses a locked one; approval ignores applied permission minutes; neither path re-derives
worked days / overtime / absence (other attendance mutations use `Payroll::EntryRecalculator`).

**H. Data the approval produces (future-contract inputs / outputs):**

| Value | Source today | Persisted / consumed by |
|---|---|---|
| `original_check_in_at` / `_out_at`, `original_check_in_source` / `_out_source` | the `AttendanceRecord` before the write (`Requests::PunchCorrectionApplier`) | `employee_requests` (Workforce table); read back by `Requests::Canceller#rollback_punch_correction` and the assessment |
| `approved_punch_at` | the reviewer's date / time (`Requests::Approver`, assessment `effective_at`) | `employee_requests` |
| corrected punch, `check_*_source = admin_manual`, late / early / worked minutes, status | `Requests::PunchCorrectionApplier` + `Attendance::RecordRecomputer` | `attendance_records` |
| penalty line amount / `original_minutes`, entry totals, `needs_review` | `Payroll::PunchCorrectionApplier` | `payroll_line_items`, `payroll_entries` |
| audit `request_type`, `correction_type`, `approved_time`, `proposed_time`, `response_note` | the request / reviewer input | `AuditLog` (`approve`) |
| audit `punch_review` (proposed vs final date / time, `change`, reviewer id / name, `reviewed_at`) | `Requests::Approver#punch_review_metadata` (request data) | `AuditLog` |
| audit `attendance_window`: `final_punch_date`, `final_punch_time`, `effective_at`, `inside_window`, `projected_worked_minutes`, `duration_severity` | `Requests::PunchCorrectionAssessment#audit_metadata` (`Attendance::PunchWindow`, a recomputed copy, `Attendance::DurationCheck`) | `AuditLog` |
| audit `confirmed_by_reviewer`, `resulting_worked_minutes`, `resulting_duration_severity` | the assessment and the saved, recomputed `AttendanceRecord` | `AuditLog` |

**I. Shared helpers.** `Requests::Canceller#covering_period` / `#daily_rate_for` / `#compute_penalty` and
`Payroll::PermissionReverter`'s private copies give identical results (period by request month, any status; daily rate
400; −100 / −200 for 40 / 120 minutes). `Payroll::PunchCorrectionApplier#open_period_covering` differs (open periods
only, by the record's work date). Consolidation is for M4, after deciding which period lookup the revert should use.

**Product questions recorded for M2 (not decided in M1):** should approval create a missing penalty line (as the revert
does)? Should a punch correction respect an applied permission? Should the effect re-derive the whole entry
(`EntryRecalculator`) like every other attendance mutation?

**Verification (seeds 20261006 / 12345 / 98765, identical; before and after M1 on `412710f`):**

| Suite | Before M1 | After M1 |
|---|---|---|
| M1 characterization (`punch_correction_effects_spec.rb`) | — | 29 / 0 |
| Punch-correction specs (17 files) | 382 / 1 | 382 / 1 — `employee_request_spec.rb:432` (documented) |
| SEC-P10-1 + locked period | 21 / 0 | 21 / 0 |
| Request security + policy | 124 / 0 | 124 / 0 |
| Pilot 9 permission-effects core | 220 / 0 | 220 / 0 |
| `spec/architecture` + `spec/requests/security` | 590 / 0 | 590 / 0 |
| Request-area set | 1622 / 27 | 1622 / 27 — the same 27 IDs |
| Pilot 10 set (`workforce-punch-correction-baseline-failures.txt`, 20 files) | — | 432 / 1 — the same ID |

`zeitwerk:check`, RuboCop (new spec) and `git diff --check` clean. No new failure; no flaky failure observed.

### 25.4 M2 — Workforce contract `Requests::PunchCorrectionEffects`

**Owner: Workforce.** The request, its lifecycle (approve, reject, cancel), the reviewer's chosen moment, the snapshot
persisted on the request and the request audit are Workforce's; the attendance record, its recomputation, the attendance
window, duration checks, penalty lines, payroll periods and entries are Attendance & Payroll's. Named in Workforce's
request namespace next to `Requests::PermissionPayrollEffects` (Pilot 9). Struct value objects (`keyword_init`, the
project convention); the contract source names nothing from Attendance & Payroll (asserted).

| | |
|---|---|
| `correction_facts(request:, field:, effective_at:, baseline: nil)` | Read-only, outside any transaction. Returns `Facts`: `record_found`, `check_in_at` / `check_out_at` (the live record's, or the `baseline` `Snapshot`'s for an already-applied correction), `inside_window`, `shift_starts_at` / `shift_ends_at`, `projected_worked_minutes`, `duration_severity`. Everything `Requests::PunchCorrectionAssessment` reads from Attendance & Payroll today |
| `correction_approved(request:, field:, effective_at:)` | Inside the approve transaction. Returns `Approval`: `status: :applied` with the `Snapshot` of the punches it replaced (`check_in_at`, `check_out_at`, `check_in_source`, `check_out_source`), `worked_minutes` and `duration_severity` of the saved record; or a refusal in `REFUSALS = %i[payroll_locked no_attendance_record check_out_not_after_check_in check_out_before_check_in]` — nothing written. Never writes the request, its status, `approved_punch_at`, the snapshot columns or the audit: Workforce persists them from the result |
| `correction_cancelled(request:, field:, snapshot:)` | Inside the cancel transaction. Restores attendance from the `Snapshot` and the payroll it owns. Returns a `Symbol` in `CANCEL_RESULTS = %i[reverted payroll_locked no_attendance_record]` |
| Arguments | `field` (`:check_in` / `:check_out`, `EmployeeRequest#correction_field`) and `effective_at` (the reviewer's final moment) are request data, computed by Workforce; anything else raises `ArgumentError` before the handler runs |
| Results | Validated: a non-`Facts`, a non-`Approval`, an applied `Approval` without a `Snapshot`, an unknown status or cancel result raise `ArgumentError`, so no attendance / payroll record crosses the contract |
| Errors | Refusals are values, not exceptions. An unexpected handler error propagates; the caller maps it in M3 to today's behaviour (approval: the applier's `failure(e.message)`, the transaction rolled back; cancellation: `RecordInvalid` → `err(messages)`, anything else rolls the cancel back un-rescued) |
| Messages | Refusal reasons are symbols; the user-facing strings (`requests.errors.cannot_approve_finalized`, `no_attendance_record`, `check_out_not_after_check_in`, `check_out_before_check_in`, `cannot_cancel_finalized`) stay in Workforce |
| Registration | `register` rejects a handler missing an operation; no handler → `NotRegistered` (a `StandardError`). Wired in `config/initializers/request_punch_correction_effects.rb` (`to_prepare`) |
| No `actor` | Neither path uses one below the request; the caller writes the `approve` / `cancel` audit |

**Atomicity is preserved by construction:** approval stays one transaction in `Requests::Approver` (request approved +
`approved_punch_at` + snapshot + `correction_approved`), the audit after commit; a refusal or an error rolls the
whole approval back. Cancellation stays one transaction in `Requests::Canceller` (`correction_cancelled` + cancelled),
the audit inside it as today. Authorization is untouched (policies, `self_approval?`, submitter rule).

**Implementation (Attendance & Payroll): `Attendance::PunchCorrectionEffects`.**

* `correction_facts` is implemented: `Attendance::PunchWindow`, `AttendanceRecord` for the request's date,
  `Attendance::RecordRecomputer` on an unsaved copy, `Attendance::DurationCheck` — the same reads as the assessment,
  pinned by parity examples (inside / outside the window, overnight abnormal duration, missing punch, no record, an
  applied correction against its baseline) and a reads-only example. (`record_found` uses `!record.nil?`: on
  `AttendanceRecord`, `present?` is the `present` status enum predicate.)
* `correction_approved` / `correction_cancelled` raise `NotImplementedError` ("lands with Pilot 10 M3 + M4"). The logic
  is still Workforce's (`Requests::PunchCorrectionApplier`, `Requests::Canceller#rollback_punch_correction` and its
  helpers); delegating to it from here would be the circular contract → Workforce shape rejected in Pilot 9 M3-B. No
  caller uses them in M2 (asserted: only the contract and the implementation name `Requests::PunchCorrectionEffects`).

**Sequencing for M3 / M4 (decided here):** M3 may route the assessment's attendance reads through `correction_facts`
on its own (implemented, parity-tested). Approval and cancellation are routed **together with M4** — the moving of
the applier's attendance / payroll writes and the canceller's six punch methods (`rollback_punch_correction`,
`rollback_punch_payroll`, `restore_penalty_line_item`, `covering_period`, `daily_rate_for`, `compute_penalty`) into
Attendance & Payroll — as Pilot 9 combined M3-B + M4. The snapshot write moves the other way: today
`Requests::PunchCorrectionApplier` writes it with `update_columns` from inside the attendance step; after M4 the
implementation returns it in `Approval#snapshot` and Workforce writes it.

**Approved product decisions for M4 (recorded in M2, not implemented; they change behaviour pinned by M1 and
need their own characterization updates):**

* **A — create missing penalty lines.** Approval creates a late / early-leave line that does not exist yet when the
  corrected punch produces a penalty, as cancellation already does (M1 §E "lines that do not exist are never created").
* **B — respect approved permission minutes.** Approval applies the permission minutes already applied to the line
  instead of recomputing from the full new minutes (M1 §E "ignores an approved permission").
* **C — `Payroll::EntryRecalculator`.** The payroll effect re-derives the entry through `Payroll::EntryRecalculator`,
  like every other attendance mutation, instead of `Payroll::PunchCorrectionApplier` patching lines (worked days /
  overtime / absence re-derived; M1 §E "worked days / overtime are not re-derived"). The period lookup (open by work
  date vs request month in any status, M1 §I) is settled with it.

**Callers not changed:** `Requests::Approver#approve_punch_correction`, `Requests::PunchCorrectionApplier`,
`Requests::Canceller#rollback_punch_correction`, `Requests::PunchCorrectionAssessment` and the views are as in M1.

**Specs:** `spec/services/requests/punch_correction_effects_spec.rb` (18) — registration (implementation registered,
incomplete handler rejected, `NotRegistered`), argument / result validation (field, snapshot, `Facts`, every refusal,
malformed `Approval`s, cancel results, error propagation), `correction_facts` parity and reads-only, approve / cancel not
implemented and writing nothing. `spec/architecture/workforce_punch_correction_boundary_spec.rb` (7) — contract names no
Attendance & Payroll (incl. `Shifts::`); the implementation calls no Workforce service other than the contract's value
types, never writes request status, `approved_punch_at`, the snapshot columns or the audit; the implementation is named
only by itself and the composition root; no caller routed yet; planted probes. Physical probe: `PayrollEntry` planted
in the contract and `EmployeeRequest` in the implementation → 2 failures; restored → 7 / 0.

**Verification (seeds 20261006 / 12345 / 98765):**

Identical under all three seeds, compared by exact failure ID with M1 (`5c8729e`):

| Suite | M1 | M2 |
|---|---|---|
| M2 contract + boundary | — | 25 / 0 (18 + 7) |
| M1 characterization | 29 / 0 | 29 / 0 |
| Punch-correction specs (17 files) | 382 / 1 | 382 / 1 — `employee_request_spec.rb:432` (documented) |
| SEC-P10-1 + locked period | 21 / 0 | 21 / 0 |
| Request security + policy | 124 / 0 | 124 / 0 |
| Pilot 9 permission-effects core (`spec/services/requests` now includes the contract spec) | 220 / 0 | 238 / 0 (+18) |
| `spec/architecture` + `spec/requests/security` | 590 / 0 | 597 / 0 (+7) |
| Request-area set | 1622 / 27 | 1622 / 27 — the same 27 IDs |
| Pilot 10 set (20 files) | 432 / 1 | 432 / 1 — the same ID |

`zeitwerk:check`, RuboCop and `git diff --check` clean. No new failure; no flaky failure observed.
