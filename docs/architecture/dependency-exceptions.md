# Classified cross-domain exceptions (D4 register)

**Status:** authoritative register of the cross-domain dependencies that may remain under decision **D4**
(`module-boundaries.md` §20.3, 2026-10-22). Each has an explicit owner, a documented reason and scope, a guard that
protects the boundary, and a disposition with a review condition. A documented exception is not a violation; a new
cross-domain dependency is never left unclassified — the enforced dependency inventory
(`spec/architecture/dependency_inventory_spec.rb`, `script/architecture/dependency_inventory.rb`) fails on it.

`dependency_inventory_spec.rb` requires the **Checker exceptions** table below to list exactly the IDs of
`ArchitectureTools::DependencyInventory::CLASSIFIED`, and every one of them to still match a real reference (a
resolved exception must be removed from both). Scope = source files × target constants, exactly as in `CLASSIFIED`.

Owners: OA Organization & Access · WF Workforce · AP Attendance & Payroll · IP Inventory & Purchasing · FS Finance &
Sales · RP Reporting · SK Shared Kernel · INFRA Infrastructure / UI shell.

## Checker exceptions

| ID | Owner | Scope (source → targets) | Reason | Guard | Disposition / review condition |
|---|---|---|---|---|---|
| X-OA-INV | OA | `app/models/{user,business,branch}.rb` → any domain (associations, `User#effective_shift_assignment_on`) | Inverse lifecycle associations of the shared tenant / account models and the User stewardship helpers (§3.2, §10) | `organization_access_outbound_boundary_spec.rb` (inverse associations frozen per domain), `organization_access_membership_boundary_spec.rb` | Keep. Long-term target: move each inverse association to its owning domain (§12.2). Review when an association is added or a model moves |
| X-OA-BRANCH-PAGE | OA | `app/controllers/admin/branches_controller.rb` → `ShiftAssignment`, `EmployeeRequest`, `PayrollEntry`, `Payroll::EntryViewAudit` | The branch page is a cross-domain dashboard: staff (WF), pending / recent requests (WF), payroll summary and its salary-view audit (AP, since PR #46) | `organization_access_membership_boundary_spec.rb` (staff lines); this inventory (constant set) | Keep (read-only + Infrastructure view audit, as D-R2). Target: Reporting / UI composition (OA-X). Review when the branch page changes |
| X-OA-BRANCH-VIEWS | OA | `app/views/admin/branches/**` → `ShiftAssignment`, `PosTerminal` | Branch staff list; the terminal section composed into the branch form (D-P12-6) | `organization_access_membership_boundary_spec.rb`, `finance_sales_pos_terminal_boundary_spec.rb` | Keep (UI composition, read-only). Review with X-OA-BRANCH-PAGE |
| X-OA-LOGIN-PAYLOAD | OA | `app/controllers/api/v1/sessions_controller.rb` → `ShiftAssignment` | API login payload `checkin_branch_ids` (the mixed OA / WF / AP session payload, §17) | `organization_access_membership_boundary_spec.rb` | Keep until the API phase redesigns the session payload (a WF read interface then) |
| X-UI-WORKSPACE | INFRA | `app/helpers/workspace_helper.rb` → any domain | UI-shell navigation registry: `policy(Model)` gates and two workspace permission lists | `organization_access_outbound_boundary_spec.rb` | Keep (§15 UI shell) |
| X-UI-SIDEBAR | INFRA | `app/views/layouts/_sidebar.html.erb` → any domain | UI-shell navigation entries (`policy(Model)` gates, admin paths) | `workforce_catalog_boundary_spec.rb`, `attendance_payroll_{biometric,obligation}_boundary_spec.rb`, `permission_role_boundary_spec.rb` | Keep (§15 UI shell) |
| X-INFRA-PUNDIT | INFRA | `app/policies/application_policy.rb` → `EmployeeScope`, `BranchScope` | The Pundit mechanism delegates visibility to the OA scope rules (§16, §18 rule 11) | `organization_access_membership_boundary_spec.rb`; security suites | Keep (by design) |
| X-SK-CURRENCY | SK | `app/helpers/application_helper.rb` → `Business::CURRENCIES` | `format_currency` reads the business currency table (Shared Kernel money formatting, §15) | This inventory (constant set) | Keep. Review if currency settings move to `settings_for` (§20.1) |
| X-AP-HELPER-BADGE | AP | `app/helpers/application_helper.rb` → `PayrollAdjustment::POSITIVE_TYPES` | Payroll-adjustment badge helper of the payroll screens, hosted in the shared helper | `workforce_request_validation_reads_boundary_spec.rb` (count frozen at 1) | Keep. Optional cleanup: move to a payroll helper |
| X-WF-HELPER-PERMISSION | WF | `app/helpers/application_helper.rb` → `ShiftAssignment` | `requested_permission_summary` — a WF request-display helper (only caller `employee_requests/show`) hosted in the shared helper | This inventory (constant set) | Keep. Optional cleanup: move to an employee-requests helper (Rails includes all helpers, no behaviour change) |
| X-FS-PAYMENT-METHODS | FS | `app/controllers/application_controller.rb` → `PaymentMethod` | `business_payment_methods` — the single payment-method loader for the FS controllers and views, which sit on two controller bases (`ApplicationController`, `Finance::BaseController`) | This inventory (constant set) | Keep. Optional cleanup: an FS controller concern when the FS controller hierarchy is unified |
| X-WF-PENALTY-OPTIONS | WF | `app/views/admin/shifts/**` → `PenaltyRule` | Shift form penalty-rule option lists (Pilot 4 read-only UI composition) | `attendance_payroll_penalty_rule_boundary_spec.rb`, `workforce_shift_scheduling_boundary_spec.rb` (4 lines frozen) | Keep |
| X-WF-REQUEST-ADVANCE | WF | `app/models/employee_request.rb` → `Advance` | `EmployeeRequest has_one :advance` — the read / lifecycle association of the Batch A classified sites | `workforce_request_advance_boundary_spec.rb` | Keep. Review with F-A5 / BUG-010 |
| X-WF-SHIFT-PENALTY-RULES | WF | `app/models/shift.rb` → `PenaltyRule` | `Shift has_many :penalty_rules, dependent: :destroy, autosave: true` — the lifecycle association behind the Pilot 4 staging contract | `attendance_payroll_penalty_rule_boundary_spec.rb` | Keep |
| X-INFRA-AUDIT-ACTOR | INFRA | `app/models/audit_log.rb` → `Business`, `User` | The cross-domain audit store references the acting account and its business (§16 Audit) | This inventory (constant set) | Keep (by design) |
| X-SK-VOIDABLE-ACTOR | SK | `app/models/concerns/voidable.rb` → `User` | `Voidable` records who voided (`belongs_to :voided_by`) — the immutability contract (§15) | This inventory (constant set) | Keep (by design) |
| X-WF-OBLIGATIONS-CARD | WF | `app/views/admin/users/show.html.erb` → `EmployeeObligation` | Employee-page obligations card, loaded only under `EmployeeObligationPolicy` (SEC-M2-5; the obligations half of Q-M2-5) | `attendance_payroll_obligation_boundary_spec.rb` | Keep. Optional: compose it like the salary card (SAL, `Employee::ProfilePanels`) |
| X-IP-FS-DISPLAY | IP | The 10 Inventory files of `inventory_finance_goods_receipt_payment_boundary_spec.rb` rule 3 → `FinancialSettlement`, `CustodyAccount`, `CustodyTransaction`, `CustodyAccountPolicy`, `Settleable`, `Finance::CustodyBalance` | Display reads and model references of the settlement / custody ledgers (IP-R). Every write goes through the Batch S / S2 contracts | `inventory_finance_goods_receipt_payment_boundary_spec.rb` rule 3 (frozen per file); rule 1 (no write) | Keep. Optional: an FS read interface for previews |
| X-IP-REPORT-INFRA | FS | `app/controllers/laundry/reports/branch_consumption_controller.rb` → `Finance::Reports::{Column,Table,CsvExporter}` | TD-R-1: the laundry consumption CSV reuses the FS report table / CSV infrastructure — no business data crosses | This inventory (constant set) | Keep. Move to the Shared Kernel / Infrastructure if a third domain needs it |
| X-RP-HOST | FS | `app/controllers/finance/reports_controller.rb` → `Finance::Reports::{BranchProfitability,ExpenseSources,ExpenseDetails,ExpenseDetailsCsvExporter}` | The FS reports controller hosts the two Reporting actions (D-R1) | `reporting_read_only_boundary_spec.rb` | Keep |

## Outside the checker's static reach

| ID | Owner | Item | Decision (2026-10-22) | Guard |
|---|---|---|---|---|
| X-GR-UI | FS (workflow) / IP (host) | The goods-receipt settlement screen (`inventory/goods_receipt_settlements`, routes under `/inventory`) is hosted by Inventory & Purchasing although the later-settlement workflow is Finance & Sales' (§8 item 5). Its writes already go through `Inventory::GoodsReceiptPaymentEffects` (Batch S) | Keep the route and host as they are; moving the screen is a separately scoped route / UX change, not part of the migration | `inventory_finance_goods_receipt_payment_boundary_spec.rb` (the screen's recorder service calls exactly `payment_source_kind?`, `payer_custody_account_id`, `record_settlement`; the controller's FS reads are frozen) and `X-IP-FS-DISPLAY` |
| X-PS-LOCATION | AP | `Employee::PerformanceScorer` lives in `app/services/employee/` (a WF folder) but is AP-owned (§10.1); its callers are AP and Reporting | No exception needed — not a cross-domain dependency (the inventory maps the file and the constant to AP). Relocation would rename the constant (`migration-pattern.md` rule F); optional | The inventory's file and constant mapping |
| X-EVENTS | all | The domain events named in §4–§8 / §14.1 | D2: synchronous contracts are the standard; events are a possible future option, not required | — |
