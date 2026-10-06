# Next Migration Pilot — Candidate Analysis

**Status:** History of the pilot selections, plus the pilot status records.

* **Pilot 2, Workforce Department + JobTitle:** COMPLETE and pushed (`cafb6f6`, `b872d7a`, `0aa0066`).
* **Pilot 3, Workforce Performance:** COMPLETE and pushed (`8c1e2df`, `309fcc4`, `d7e83ca`, `ae74dcc`). It is on
  `origin/feature/api-foundation` at `ae74dcc`.
* **Pilot 4:** not selected.

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

**Status:** M0 audit, Pilot 1 selection and **security hardening complete** (§5.1). **Pilot 1 implementation has
not started:** no model has moved, no M1 characterization exists, and no schema, migration, route or API has
changed. The only production changes are the five security fixes in §5.1, each in its own `fix:` commit. Milestone 1
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
| CG-2 Device CRUD + `regenerate_token` contract (redirects, flash, token changes, **old token rejected** by the punch API) | REQUIRED |
| CG-3 Punch API negatives not yet pinned: unknown token (vs inactive), device of business B with employee of B only, duplicate or stale punch outcome | REQUIRED |
| CG-4 Punch-log visibility: who may list and show logs, cross-business 404 on `show` | REQUIRED (after the SEC-M2-8 decision) |
| CG-5 `destroy` nullifies logs (`dependent: :nullify`) | Optional |

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
| 2 | M1 Characterization | M1 | CG-2, CG-3, CG-4 against the fixed code; default and random order | `test:` |
| 3 | M2 Boundary + M6 Physical + M7/M8 | M6 + M7 + M8 | New AP boundary spec (constants `BiometricDevice` / `BiometricPunchLog`, tables, allow-list: `Business` inverse, sidebar, `workspace_helper`, AP-internal writers) with a probe; `git mv` of the 2 models into the collapsed AP directory + initializer + location spec; verification + status section | `refactor:` (one commit, as in Pilot 3) |

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
| Existing | AP-D2 (`waive?`), MIG-1, MIG-2, TD-FIN1, TD-PERF1 (unchanged) |

## 11. Open architectural questions

| # | Question |
|---|---|
| Q-M2-1 | Folder name for AP models: `app/models/attendance_payroll/` (consistent with `organization_access/`, `workforce/`)? It is needed before Pilot 1's physical step |
| Q-M2-2 | SEC-M2-8: the punch-log viewing gate (`manage_devices`, or `view_attendance` + data scope)? |
| Q-M2-3 | After SEC-M2-2 (now gated like `AttendanceRecordsController`): keep `Admin::AttendanceRecordsController`, or retire it in favour of `AttendanceRecordsController`? |
| Q-M2-4 | SEC-M2-6: may a salary manager change their **own** salary (segregation of duties), and should `manage_salary_profiles` scope apply to the web path? |
| Q-M2-5 | Employee-page salary and obligations cards (SEC-M2-5): gate them with AP policies inside the WF view (exception), or render them as an AP-contributed panel (UI composition, `module-boundaries.md` §12.1)? |
| Q-M2-6 | Should `BiometricPunchLog` be documented as the channel-neutral "punch log" (DS-8)? Naming only; the constant stays |
| Q-P3-1 | `Employee::PerformanceScorer` ownership (carried over) |

## 12. Status

* **Done:**
  * M0 audit, security audit and Pilot 1 selection (approved: Biometric Device + PunchService).
  * Security hardening: SEC-M2-1 `28b2100`, SEC-M2-2 `ca66c43`, SEC-M2-3 + SEC-M2-9 `3d9127e`, SEC-M2-4
    `a384319`.
* **Not started:** Pilot 1 (M1 characterization, AP boundary spec, initializer, any model move).
* **Not pushed:** all commits are local on `feature/milestone-2-attendance-payroll`.
* **Before Pilot 1 M1:** the final full verification run; answers to Q-M2-1 (folder name) and Q-M2-2 (SEC-M2-8
  punch-log gate, part of CG-4).
