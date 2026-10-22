# frozen_string_literal: true

# Repository-wide domain dependency inventory (module-boundaries.md §19 step 0:
# "dependency checks in report-only mode record every current violation").
#
# Maps every file under app/ to one of the six domains of module-boundaries.md
# (or the Shared Kernel / Infrastructure / frontend layers), finds the constants
# each Ruby / ERB file names, resolves each constant to its owning domain, and
# classifies every cross-domain reference:
#
#   allowed      — the direction module-boundaries.md §12.1 allows (a downstream
#                  domain reading an upstream one; Reporting reading any domain;
#                  any file using the Shared Kernel / Infrastructure);
#   classified   — an upward or sideways reference already classified by an
#                  existing boundary spec or decision (CLASSIFIED, each entry
#                  citing where);
#   unclassified — everything else.
#
# ENFORCED since 2026-10-22 (decision D3, module-boundaries.md §20.3; it was
# report-only from 9468678): spec/architecture/dependency_inventory_spec.rb fails
# on any unclassified reference, unmapped app/ file or schema table, or stale
# exception, and proves detection with planted probes. `bin/rails
# architecture:dependency_report` writes the deterministic report
# docs/architecture/dependency-inventory-report.txt.
#
# Scope and limits (by design, recorded in the report header): constants,
# association macros and literal SQL table names are detected; dynamic constants,
# polymorphic / through: associations, queries without a literal table name and
# runtime behaviour are not — the per-component boundary specs cover those.
# Comments, i18n keys and other string contents never count.
# * Not autoloaded (script/ is outside Zeitwerk); loaded only by the spec and the
#   rake task. It changes no application behaviour.
require "set"

module ArchitectureTools
  module DependencyInventory
    module_function

    OA = :organization_access
    WF = :workforce
    AP = :attendance_payroll
    IP = :inventory_purchasing
    FS = :finance_sales
    RP = :reporting
    SHARED   = :shared_kernel
    INFRA    = :infrastructure
    FRONTEND = :frontend

    DOMAINS = [ OA, WF, AP, IP, FS, RP ].freeze
    LAYERS  = (DOMAINS + [ SHARED, INFRA, FRONTEND ]).freeze

    # module-boundaries.md §12.1: the upstream domains each domain may depend on.
    UPSTREAM = {
      OA => [],
      WF => [ OA ],
      AP => [ OA, WF ],
      IP => [ OA ],
      FS => [ OA, WF, AP, IP ],
      RP => [ OA, WF, AP, IP, FS ]
    }.freeze

    # ---------------------------------------------------------------- files ---

    # Ordered: the first matching rule decides. Paths are relative to Rails.root.
    FILE_RULES = [
      # Frontend assets: mapped, never scanned (no Ruby constants).
      [ %r{\Aapp/(assets|javascript)/}, FRONTEND ],

      # Reporting (module-boundaries.md §9; reporting_read_only_boundary_spec.rb).
      [ %r{\Aapp/controllers/(dashboard|operations_dashboard)_controller\.rb\z}, RP ],
      [ %r{\Aapp/controllers/admin/dashboard_controller\.rb\z}, RP ],
      [ %r{\Aapp/controllers/finance/dashboard_controller\.rb\z}, RP ],
      [ %r{\Aapp/controllers/laundry/reports/cost_summary_controller\.rb\z}, RP ],
      [ %r{\Aapp/services/dashboard/(owner_data|area_manager_data)\.rb\z}, RP ],
      [ %r{\Aapp/services/finance/(dashboard/|dashboard_filters\.rb)}, RP ],
      [ %r{\Aapp/services/finance/reports/(branch_profitability|expense_sources|verified_revenue|laundry_cost_summary|expense_details|expense_details_csv_exporter)\.rb\z}, RP ],
      [ %r{\Aapp/views/(dashboard|operations_dashboard)/}, RP ],
      [ %r{\Aapp/views/admin/dashboard/}, RP ],
      [ %r{\Aapp/views/finance/dashboard/}, RP ],
      [ %r{\Aapp/views/laundry/reports/cost_summary/}, RP ],
      [ %r{\Aapp/policies/(operations_dashboard_policy|finance/dashboard_policy)\.rb\z}, RP ],

      # Domain files kept in shared folders (ownership by content, as already classified).
      [ %r{\Aapp/views/shared/_adjustment_already_paid_section\.html\.erb\z}, AP ], # module-boundaries.md §4.1 G (AP partial)
      [ %r{\Aapp/views/shared/_job_title_select\.html\.erb\z}, WF ],               # workforce_catalog_boundary_spec.rb
      [ %r{\Aapp/controllers/api/v1/biometric_base_controller\.rb\z}, AP ],          # device-token base of the punch API (Pilot 1)

      # Shared Kernel (§15) and Infrastructure (§16).
      [ %r{\Aapp/lib/business_day\.rb\z}, SHARED ],
      # Phone-number login-identifier primitive: every caller is Organization & Access (User, API sessions, registration).
      [ %r{\Aapp/lib/phone_number\.rb\z}, OA ],
      [ %r{\Aapp/models/concerns/(voidable|immutable_document)\.rb\z}, SHARED ],
      [ %r{\Aapp/models/concerns/settleable\.rb\z}, FS ],
      [ %r{\Aapp/models/concerns/}, INFRA ],
      [ %r{\Aapp/models/(application_record|audit_log)\.rb\z}, INFRA ],
      [ %r{\Aapp/lib/api/}, INFRA ],
      [ %r{\Aapp/controllers/concerns/}, INFRA ],
      [ %r{\Aapp/controllers/application_controller\.rb\z}, INFRA ],
      [ %r{\Aapp/controllers/api/v1/base_controller\.rb\z}, INFRA ],
      [ %r{\Aapp/controllers/admin/base_controller\.rb\z}, INFRA ],
      [ %r{\Aapp/serializers/api/v1/base_serializer\.rb\z}, INFRA ],
      [ %r{\Aapp/policies/application_policy\.rb\z}, INFRA ],
      [ %r{\Aapp/helpers/(application|attachment|workspace)_helper\.rb\z}, INFRA ],
      [ %r{\Aapp/views/(layouts|shared|pwa)/}, INFRA ],
      [ %r{\Aapp/(jobs/application_job|mailers/application_mailer)\.rb\z}, INFRA ],

      # Organization & Access (§4).
      [ %r{\Aapp/models/organization_access/}, OA ],
      [ %r{\Aapp/models/(business|branch|user|user_audit_log)\.rb\z}, OA ],
      [ %r{\Aapp/services/(organization_access|users|approvals)/}, OA ],
      [ %r{\Aapp/services/(employee_scope|branch_scope)\.rb\z}, OA ],
      [ %r{\Aapp/controllers/(users|profile)/}, OA ],
      [ %r{\Aapp/controllers/(preferences|locale)_controller\.rb\z}, OA ],
      [ %r{\Aapp/controllers/admin/(branches|settings|permission_roles|user_passwords)_controller\.rb\z}, OA ],
      [ %r{\Aapp/controllers/api/v1/sessions_controller\.rb\z}, OA ],
      [ %r{\Aapp/views/(users|profile)/}, OA ],
      [ %r{\Aapp/views/admin/(branches|settings|permission_roles|user_passwords)/}, OA ],
      [ %r{\Aapp/policies/(branch|permission_role)_policy\.rb\z}, OA ],

      # Attendance & Payroll (§6) — before Workforce, for services/employee/performance_scorer.rb (§10.1).
      [ %r{\Aapp/services/employee/performance_scorer\.rb\z}, AP ],
      [ %r{\Aapp/models/attendance_payroll/}, AP ],
      [ %r{\Aapp/services/(attendance|payroll|salary|adjustments|reports)/}, AP ],
      [ %r{\Aapp/jobs/payroll/}, AP ],
      [ %r{\Aapp/serializers/api/v1/advance_serializer\.rb\z}, AP ],
      [ %r{\Aapp/controllers/(attendance|attendance_records|adjustments|bulk_adjustments|payroll_adjustments|payroll_dashboard|payroll_entries|payroll_line_items|payroll_periods)_controller\.rb\z}, AP ],
      [ %r{\Aapp/controllers/admin/(attendance_imports|attendance_records|biometric_devices|biometric_punch_logs|penalty_rules|salary_profiles|employee_obligations)_controller\.rb\z}, AP ],
      [ %r{\Aapp/controllers/api/v1/(advances|attendance|attendance_records|payroll_adjustments|payroll_entries|payroll_line_items|payroll_periods|penalty_rules|punches|salary_profiles)_controller\.rb\z}, AP ],
      [ %r{\Aapp/controllers/api/v1/reports/}, AP ],
      [ %r{\Aapp/views/(attendance_records|adjustments|bulk_adjustments|payroll_adjustments|payroll_dashboard|payroll_entries|payroll_periods)/}, AP ],
      [ %r{\Aapp/views/admin/(attendance_imports|attendance_records|biometric_devices|biometric_punch_logs|penalty_rules|salary_profiles|employee_obligations)/}, AP ],

      # Workforce (§5).
      [ %r{\Aapp/models/workforce/}, WF ],
      [ %r{\Aapp/services/(employee_data_requests|employee|shifts|scheduling|requests|performance|workforce)/}, WF ],
      [ %r{\Aapp/services/(branch_membership\.rb|dashboard/birthdays\.rb)\z}, WF ],
      [ %r{\Aapp/controllers/(shifts|shift_assignments|employee_requests|employee_data_requests|birthday_celebrations)_controller\.rb\z}, WF ],
      [ %r{\Aapp/controllers/performance/}, WF ],
      [ %r{\Aapp/controllers/admin/(users|employee_insurance_profiles|departments|job_titles|evaluation_templates|shifts|shift_templates|shift_rule_profiles)_controller\.rb\z}, WF ],
      [ %r{\Aapp/controllers/api/v1/(shifts|shift_assignments|employee_requests)_controller\.rb\z}, WF ],
      [ %r{\Aapp/views/(shifts|shift_assignments|employee_requests|employee_data_requests|performance)/}, WF ],
      [ %r{\Aapp/views/admin/(users|employee_insurance_profiles|departments|job_titles|evaluation_templates|shifts|shift_templates|shift_rule_profiles)/}, WF ],
      [ %r{\Aapp/helpers/(employee_data_requests|shift_assignment|shift_template)_helper\.rb\z}, WF ],

      # Inventory & Purchasing (§7).
      [ %r{\Aapp/models/inventory_purchasing/}, IP ],
      [ %r{\Aapp/services/(inventory|laundry)/}, IP ],
      [ %r{\Aapp/controllers/(inventory|laundry)/}, IP ],
      [ %r{\Aapp/views/(inventory|laundry)/}, IP ],
      [ %r{\Aapp/helpers/(inventory|laundry)_helper\.rb\z}, IP ],

      # Finance & Sales (§8).
      [ %r{\Aapp/models/finance_sales/}, FS ],
      [ %r{\Aapp/services/finance/}, FS ],
      [ %r{\Aapp/services/financial_settlement_service\.rb\z}, FS ],
      [ %r{\Aapp/jobs/finance/}, FS ],
      [ %r{\Aapp/controllers/finance/}, FS ],
      [ %r{\Aapp/controllers/(till_deposits|till_handovers|till_refunds|opening_floats|deposit_responsibility_transfers)_controller\.rb\z}, FS ],
      [ %r{\Aapp/views/finance/}, FS ],
      [ %r{\Aapp/views/(till_deposits|till_handovers|till_refunds|opening_floats|deposit_responsibility_transfers)/}, FS ],
      [ %r{\Aapp/helpers/finance_helper\.rb\z}, FS ]
    ].freeze

    # Top-level models (app/models/*.rb) → owner, from module-boundaries.md §10
    # (constants, not files: a model file maps through its constant).
    MODEL_OWNERS = {
      OA => %w[Business Branch User UserAuditLog PermissionRole],
      WF => %w[EmployeeDataRequest EmployeeDataRequestEvent EmployeeDataRequestRevision EmployeeInsuranceProfile Department
               JobTitle Shift ShiftAssignment ShiftTemplate ShiftTemplateEntry ShiftRuleProfile EmployeeRequest
               EvaluationTemplate EvaluationCriterion PerformanceReview PerformanceReviewScore PerformanceObservation],
      AP => %w[AttendanceRecord AttendanceAdjustment AttendanceImportLog BiometricDevice BiometricPunchLog PenaltyRule
               SalaryProfile PayrollPeriod PayrollEntry PayrollLineItem PayrollAdjustment PayrollAdjustmentEdit
               PayrollAuditLog PayrollSnapshot PayrollPeriodBranchReview Advance EmployeeObligation ObligationDeduction
               ObligationPostponement],
      IP => %w[Warehouse WarehouseAssignment WarehouseBranchSupply Product ProductBarcode ProductCategory Brand
               ProductWarehouseSetting InventoryMovement StockIssue StockIssueItem StockIssueImportBatch
               StockIssueImportRow StockTransfer StockTransferItem StockAdjustment StockAdjustmentItem StockCount
               StockCountItem Supplier PurchaseRequest PurchaseRequestItem PurchaseRequestAdvance GoodsReceipt
               GoodsReceiptItem TowelType TowelLedgerEntry TowelTransfer TowelTransferItem TowelAdjustment LaundryBatch
               LaundryBatchConsumption LaundryStandardCostRate Service],
      FS => %w[Expense ExpenseAllocation ExpenseCategory ExpenseType ExpenseTag ExpenseTagging RecurringExpense
               RecurringExpenseAllocation CustodyAccount CustodyTransaction BalanceRequest FinancialSettlement
               PaymentMethod FinancialAdjustment DailyReconciliation TillSession TillSessionAmount TillHandover
               TillHandoverAmount TillDeposit TillRefund DepositResponsibilityTransfer RemainingDepositBalance
               RemainingDepositBalanceTransaction EmployeeReconciliationSummary EmployeeReconciliationSummaryAmount
               BankStatement BankStatementTransaction DepositMatch BankDispute SalesImport SalesTransaction PosImport
               PosImportIgnoredRow PosTransaction PosTerminal BranchRevenue],
      INFRA => %w[ApplicationRecord AuditLog]
    }.flat_map { |domain, names| names.map { |name| [ name, domain ] } }.to_h.freeze

    # Non-model constants (exact name or namespace prefix "X::") → owner. The
    # longest matching key wins, so specific overrides beat their namespace.
    CONSTANT_OWNERS = {
      # Organization & Access
      "OrganizationAccess::" => OA, "Approvals::" => OA, "Users::" => OA,
      "EmployeeScope" => OA, "BranchScope" => OA,
      # Workforce
      "Workforce::" => WF, "Requests::" => WF, "Shifts::" => WF, "Scheduling::" => WF,
      "EmployeeDataRequests::" => WF, "Performance::" => WF, "Employee::" => WF, "BranchMembership" => WF,
      "Dashboard::Birthdays" => WF, "EmployeeDataRequestsHelper" => WF, "ShiftAssignmentHelper" => WF,
      "ShiftTemplateHelper" => WF,
      # Attendance & Payroll (Employee::PerformanceScorer — module-boundaries.md §10.1)
      "Payroll::" => AP, "Attendance::" => AP, "Salary::" => AP, "Adjustments::" => AP, "Reports::" => AP,
      "Employee::PerformanceScorer" => AP, "Geo::" => AP,
      "Api::V1::AdvanceSerializer" => AP,
      # Inventory & Purchasing
      "Inventory::" => IP, "Laundry::" => IP, "InventoryHelper" => IP, "LaundryHelper" => IP,
      # Finance & Sales
      "Finance::" => FS, "FinancialSettlementService" => FS, "Settleable" => FS, "FinanceHelper" => FS,
      # Reporting (module-boundaries.md §9)
      "Dashboard::" => RP, "Finance::Dashboard::" => RP, "Finance::DashboardFilters" => RP,
      "Finance::Reports::BranchProfitability" => RP, "Finance::Reports::ExpenseSources" => RP,
      "Finance::Reports::VerifiedRevenue" => RP, "Finance::Reports::LaundryCostSummary" => RP,
      "Finance::Reports::ExpenseDetails" => RP, "Finance::Reports::ExpenseDetailsCsvExporter" => RP,
      "OperationsDashboardPolicy" => RP, "Finance::DashboardPolicy" => RP,
      # Shared Kernel / Infrastructure
      "BusinessDay" => SHARED, "PhoneNumber" => OA, "Voidable" => SHARED, "ImmutableDocument" => SHARED,
      "AuditLoggable" => INFRA, "Attachable" => INFRA, "ApplicationPolicy" => INFRA, "ApplicationController" => INFRA,
      "ApplicationHelper" => INFRA, "WorkspaceHelper" => INFRA, "AttachmentHelper" => INFRA, "ApplicationJob" => INFRA,
      "ApplicationMailer" => INFRA, "ApiResponder" => INFRA, "Api::" => INFRA
    }.freeze

    # Policies whose owner is not the owner of the model named in their prefix.
    POLICY_OWNERS = {
      "OperationsDashboardPolicy" => RP, "PayrollDashboardPolicy" => AP, "DepositVerificationPolicy" => FS,
      "UserPolicy" => WF # employee management (module-boundaries.md §5 item 9)
    }.freeze

    # ------------------------------------------------------- classification ---

    # D4 exceptions (module-boundaries.md §20.3): every upward or sideways
    # reference that may remain, each with an owner, its scope (source files and
    # target constants), the reason, and the guard that protects it. The full
    # record — disposition and review condition — is
    # docs/architecture/dependency-exceptions.md; dependency_inventory_spec.rb
    # requires both to list exactly the same IDs and every entry to still match a
    # real reference (no stale exception).
    Exception = Struct.new(:id, :owner, :files, :constants, :reason, :guard, keyword_init: true)

    CLASSIFIED = [
      Exception.new(id: "X-OA-INV", owner: OA, files: %r{\Aapp/models/(user|business|branch)\.rb\z}, constants: /./,
                    reason: "inverse lifecycle associations of Business / Branch / User and the User stewardship helpers",
                    guard: "organization_access_outbound_boundary_spec.rb, organization_access_membership_boundary_spec.rb"),
      Exception.new(id: "X-OA-BRANCH-PAGE", owner: OA, files: %r{\Aapp/controllers/admin/branches_controller\.rb\z},
                    constants: /\A(ShiftAssignment|EmployeeRequest|PayrollEntry|Payroll::EntryViewAudit)(::|\z)/,
                    reason: "the branch page is a cross-domain dashboard: staff (WF), pending / recent requests (WF), payroll summary + its view audit (AP)",
                    guard: "organization_access_membership_boundary_spec.rb (staff lines); this inventory (constant set)"),
      Exception.new(id: "X-OA-BRANCH-VIEWS", owner: OA, files: %r{\Aapp/views/admin/branches/},
                    constants: /\A(ShiftAssignment|PosTerminal)(::|\z)/,
                    reason: "branch staff list and the terminal section composed into the branch form",
                    guard: "organization_access_membership_boundary_spec.rb, finance_sales_pos_terminal_boundary_spec.rb (D-P12-6)"),
      Exception.new(id: "X-OA-LOGIN-PAYLOAD", owner: OA, files: %r{\Aapp/controllers/api/v1/sessions_controller\.rb\z},
                    constants: /\AShiftAssignment(::|\z)/,
                    reason: "API login payload checkin_branch_ids (mixed OA / WF / AP session payload, module-boundaries.md §17)",
                    guard: "organization_access_membership_boundary_spec.rb"),
      Exception.new(id: "X-UI-WORKSPACE", owner: INFRA, files: %r{\Aapp/helpers/workspace_helper\.rb\z}, constants: /./,
                    reason: "UI-shell navigation registry: policy(Model) gates and workspace permission lists",
                    guard: "organization_access_outbound_boundary_spec.rb"),
      Exception.new(id: "X-UI-SIDEBAR", owner: INFRA, files: %r{\Aapp/views/layouts/_sidebar\.html\.erb\z}, constants: /./,
                    reason: "UI-shell navigation entries (policy(Model) gates, admin paths)",
                    guard: "workforce_catalog_boundary_spec.rb, attendance_payroll_{biometric,obligation}_boundary_spec.rb, permission_role_boundary_spec.rb"),
      Exception.new(id: "X-INFRA-PUNDIT", owner: INFRA, files: %r{\Aapp/policies/application_policy\.rb\z},
                    constants: /\A(EmployeeScope|BranchScope)\z/,
                    reason: "the Pundit mechanism delegates visibility to the Organization & Access scope rules (§16, §18 rule 11)",
                    guard: "organization_access_membership_boundary_spec.rb; the security suites"),
      Exception.new(id: "X-SK-CURRENCY", owner: SHARED, files: %r{\Aapp/helpers/application_helper\.rb\z},
                    constants: /\ABusiness::CURRENCIES\z/,
                    reason: "format_currency reads the business currency table (Shared Kernel money formatting, §15)",
                    guard: "this inventory (constant set)"),
      Exception.new(id: "X-AP-HELPER-BADGE", owner: AP, files: %r{\Aapp/helpers/application_helper\.rb\z},
                    constants: /\APayrollAdjustment::POSITIVE_TYPES\z/,
                    reason: "payroll-adjustment badge helper used by payroll screens, hosted in the shared helper",
                    guard: "workforce_request_validation_reads_boundary_spec.rb (count frozen at 1)"),
      Exception.new(id: "X-WF-HELPER-PERMISSION", owner: WF, files: %r{\Aapp/helpers/application_helper\.rb\z},
                    constants: /\AShiftAssignment\z/,
                    reason: "requested_permission_summary — a Workforce request-display helper (only caller: employee_requests/show) hosted in the shared helper",
                    guard: "this inventory (constant set)"),
      Exception.new(id: "X-FS-PAYMENT-METHODS", owner: FS, files: %r{\Aapp/controllers/application_controller\.rb\z},
                    constants: /\APaymentMethod\z/,
                    reason: "business_payment_methods — the single payment-method loader for the Finance & Sales controllers / views (two controller bases), hosted in ApplicationController",
                    guard: "this inventory (constant set)"),
      Exception.new(id: "X-WF-PENALTY-OPTIONS", owner: WF, files: %r{\Aapp/views/admin/shifts/}, constants: /\APenaltyRule(::|\z)/,
                    reason: "shift form penalty-rule option lists (Pilot 4 read-only UI composition)",
                    guard: "attendance_payroll_penalty_rule_boundary_spec.rb, workforce_shift_scheduling_boundary_spec.rb"),
      Exception.new(id: "X-WF-REQUEST-ADVANCE", owner: WF, files: %r{\Aapp/models/employee_request\.rb\z}, constants: /\AAdvance\z/,
                    reason: "EmployeeRequest has_one :advance — read / lifecycle association (Batch A classified site)",
                    guard: "workforce_request_advance_boundary_spec.rb"),
      Exception.new(id: "X-WF-SHIFT-PENALTY-RULES", owner: WF, files: %r{\Aapp/models/shift\.rb\z}, constants: /\APenaltyRule\z/,
                    reason: "Shift has_many :penalty_rules (dependent: :destroy, autosave: true) — the lifecycle association behind the Pilot 4 staging contract",
                    guard: "attendance_payroll_penalty_rule_boundary_spec.rb"),
      Exception.new(id: "X-INFRA-AUDIT-ACTOR", owner: INFRA, files: %r{\Aapp/models/audit_log\.rb\z}, constants: /\A(Business|User)\z/,
                    reason: "the cross-domain audit store references the acting account and its business (§16 Audit)",
                    guard: "this inventory (constant set)"),
      Exception.new(id: "X-SK-VOIDABLE-ACTOR", owner: SHARED, files: %r{\Aapp/models/concerns/voidable\.rb\z}, constants: /\AUser\z/,
                    reason: "Voidable records who voided (belongs_to :voided_by, User) — the immutability contract of §15",
                    guard: "this inventory (constant set)"),
      Exception.new(id: "X-WF-OBLIGATIONS-CARD", owner: WF, files: %r{\Aapp/views/admin/users/show\.html\.erb\z},
                    constants: /\AEmployeeObligation(::|\z)/,
                    reason: "employee-page obligations card under EmployeeObligationPolicy (SEC-M2-5; Q-M2-5 obligations half)",
                    guard: "attendance_payroll_obligation_boundary_spec.rb"),
      Exception.new(id: "X-IP-FS-DISPLAY", owner: IP,
                    files: %r{\Aapp/(models/(goods_receipt|purchase_request|purchase_request_advance)\.rb|services/inventory/(custody_payment_preview|goods_receipt_draft_service)\.rb|controllers/inventory/(goods_receipt_settlements|goods_receipts|purchase_requests)_controller\.rb|views/inventory/(goods_receipt_settlements/new|goods_receipts/show)\.html\.erb)\z},
                    constants: /\A(FinancialSettlement|CustodyAccount|CustodyTransaction|CustodyAccountPolicy|Settleable|Finance::CustodyBalance)(::|\z)/,
                    reason: "Inventory display reads and model references of the settlement / custody ledgers (IP-R; writes go through the Batch S / S2 contracts)",
                    guard: "inventory_finance_goods_receipt_payment_boundary_spec.rb rule 3 (frozen per file)"),
      Exception.new(id: "X-IP-REPORT-INFRA", owner: FS, files: %r{\Aapp/controllers/laundry/reports/branch_consumption_controller\.rb\z},
                    constants: /\AFinance::Reports::(Column|Table|CsvExporter)\z/,
                    reason: "TD-R-1: the laundry consumption CSV reuses the Finance & Sales report table / CSV infrastructure (no business data)",
                    guard: "this inventory (constant set)"),
      Exception.new(id: "X-RP-HOST", owner: FS, files: %r{\Aapp/controllers/finance/reports_controller\.rb\z},
                    constants: /\AFinance::Reports::(BranchProfitability|ExpenseSources|ExpenseDetails|ExpenseDetailsCsvExporter)\z/,
                    reason: "the Finance & Sales reports controller hosts the two Reporting actions (D-R1)",
                    guard: "reporting_read_only_boundary_spec.rb")
    ].freeze

    # ------------------------------------------------------------- scanning ---

    CONSTANT = /(?<![\w:@$.])(?:::)?([A-Z][A-Za-z0-9_]*(?:::[A-Z][A-Za-z0-9_]*)*)/

    Reference = Struct.new(:path, :source, :target, :constant, :kind, :line, :status, :exception, keyword_init: true) do
      def reason = exception ? "#{exception.id} (owner #{exception.owner}) — #{exception.guard}" : nil
    end

    def root
      defined?(Rails) ? Rails.root.to_s : File.expand_path("../..", __dir__)
    end

    def app_files
      Dir.glob(File.join(root, "app", "**", "*")).select { |f| File.file?(f) }
         .map { |f| f.delete_prefix("#{root}/") }.sort
    end

    # The domain of a file, or nil when no rule maps it (reported as unmapped).
    def domain_of_file(path)
      if (model = path[%r{\Aapp/models/([a-z0-9_]+)\.rb\z}, 1])
        return MODEL_OWNERS[camelize(model)]
      end
      if (policy = path[%r{\Aapp/policies/([a-z0-9_]+)_policy\.rb\z}, 1])
        name = "#{camelize(policy)}Policy"
        return POLICY_OWNERS[name] || MODEL_OWNERS[camelize(policy)] || rule_domain(path)
      end
      rule_domain(path)
    end

    def rule_domain(path)
      FILE_RULES.find { |pattern, _| pattern.match?(path) }&.last
    end

    # The owner of a constant, or nil when it is not an application constant
    # (Ruby, Rails, gems) — those are never dependencies between domains.
    def owner_of(constant)
      name = constant.delete_prefix("::")
      return MODEL_OWNERS[name] if MODEL_OWNERS.key?(name)
      return POLICY_OWNERS[name] if POLICY_OWNERS.key?(name)

      key = CONSTANT_OWNERS.keys.select { |k| k.end_with?("::") ? name.start_with?(k) : (name == k || name.start_with?("#{k}::")) }
                           .max_by(&:length)
      return CONSTANT_OWNERS[key] if key

      if (base = name[/\A([A-Z][A-Za-z0-9]*)Policy(::Scope)?\z/, 1])
        return MODEL_OWNERS[base]
      end
      if (head = name[/\A([A-Z][A-Za-z0-9]*)::/, 1]) && MODEL_OWNERS.key?(head)
        return MODEL_OWNERS[head] # Model::CONSTANT, Model::Nested
      end

      nil
    end

    # A constant written unqualified inside a namespaced file (`ExpenseSources`
    # inside app/services/finance/reports/) is resolved against the namespaces
    # its path implies, innermost first — only when that exact constant exists
    # (Ruby's lexical lookup would otherwise also find top-level ones).
    def resolve(constant, path)
      return constant if constant.start_with?("::") || owner_of(constant)

      namespaces = path.sub(%r{\Aapp/[^/]+/}, "").split("/")[0..-2].map { |segment| camelize(segment) }
      namespaces.size.downto(1).each do |depth|
        candidate = "#{namespaces.first(depth).join('::')}::#{constant}"
        return candidate if owner_of(candidate) && existing_constant?(candidate)
      end
      constant
    end

    # Static: the constants app/ files define, as Zeitwerk expects them
    # (cpath_expected_at loads nothing), so the answer never depends on what
    # happens to be autoloaded already.
    def existing_constant?(name) = defined_constants.include?(name)

    def defined_constants
      @defined_constants ||= begin
        loader = Rails.autoloaders.main
        Dir.glob(File.join(root, "app", "**", "*.rb")).filter_map do |file|
          loader.cpath_expected_at(file)
        rescue StandardError
          nil
        end.to_set
      end
    end

    # Directory namespaces with no file of their own (`Finance::Dashboard`): a
    # namespace token is not a dependency on any class.
    def implicit_namespaces
      @implicit_namespaces ||= defined_constants.flat_map do |cpath|
        parts = cpath.split("::")
        (1...parts.size).map { |i| parts.first(i).join("::") }
      end.to_set - defined_constants
    end

    def code_lines(path, content = nil)
      source = content || File.read(File.join(root, path))
      source = source.gsub(/<%#.*?%>/m) { |c| "\n" * c.count("\n") } if path.end_with?(".erb")
      if path.end_with?(".erb")
        # Only Ruby inside ERB tags is code; HTML text never is.
        source = source.gsub(/(?:\A|%>)(.*?)(?=<%|\z)/m) { |m| m.gsub(/[^\n]/, " ") }
      end
      source.each_line.with_index(1)
            .reject { |line, _| line.lstrip.start_with?("#") }
            .map { |line, number| [ strip_strings(line).sub(/\s#(?![{]).*$/, ""), number ] }
    end

    def strip_strings(line)
      line.gsub(/"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'|%[iIwW]\[[^\]]*\]/, '""')
    end

    # Every cross-domain reference of a file, of three kinds:
    #   constant    — an application constant named in code;
    #   association — a belongs_to / has_one / has_many / habtm macro, resolved to
    #                 its model by class_name: or by the inflected association name
    #                 (polymorphic and through: associations whose name is not a
    #                 model resolve to nothing — a recorded limit);
    #   sql         — a table named after FROM / JOIN / INTO / UPDATE inside a
    #                 string literal (raw SQL fragments).
    def references_in(path, content = nil)
      source = domain_of_file(path)
      return [] if source.nil? || source == FRONTEND
      return [] unless content || path.end_with?(".rb", ".erb")

      code = code_lines(path, content)
      raw  = raw_lines(path, content).to_h { |line, number| [ number, line ] }
      code.flat_map do |line, number|
        found = line.scan(CONSTANT).flatten.map { |written| [ resolve(written, path), :constant ] }
        if (constant = association_target(raw[number].to_s))
          found << [ constant, :association ]
        end
        sql_tables(raw[number].to_s).each { |table| found << [ TABLE_OWNERS.fetch(table)[:model], :sql ] }

        found.filter_map do |constant, kind|
          next if implicit_namespaces.include?(constant.delete_prefix("::"))

          target = owner_of(constant)
          next if target.nil? || target == source || [ SHARED, INFRA ].include?(target)

          status, exception = classify(path, source, target, constant)
          Reference.new(path: path, source: source, target: target, constant: constant.delete_prefix("::"), kind: kind,
                        line: number, status: status, exception: exception)
        end
      end
    end

    ASSOCIATION = /\A\s*(belongs_to|has_one|has_many|has_and_belongs_to_many)\s+:(\w+)(.*)\z/

    def association_target(line)
      macro, name, rest = line.match(ASSOCIATION)&.captures
      return nil unless macro
      return nil if rest.match?(/\bpolymorphic:\s*true/)

      explicit = rest[/\bclass_name:\s*["']:{0,2}([A-Z][\w:]*)["']/, 1]
      return explicit if explicit

      singular = %w[belongs_to has_one].include?(macro) ? name : singularize(name)
      model = camelize(singular)
      MODEL_OWNERS.key?(model) ? model : nil
    end

    SQL_TABLE = /\b(?:FROM|JOIN|INTO|UPDATE)\s+"?([a-z_][a-z0-9_]*)"?/ # upper-case keywords only (prose stays prose)

    def sql_tables(line)
      line.scan(/"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'/).flat_map do |literal|
        literal.scan(SQL_TABLE).flatten.map(&:downcase).select { |table| TABLE_OWNERS.key?(table) && TABLE_OWNERS[table][:model] }
      end.uniq
    end

    # Comments dropped, strings KEPT (associations' class_name:, SQL literals).
    def raw_lines(path, content = nil)
      source = content || File.read(File.join(root, path))
      source = source.gsub(/<%#.*?%>/m) { |c| "\n" * c.count("\n") } if path.end_with?(".erb")
      source.each_line.with_index(1).reject { |line, _| line.lstrip.start_with?("#") }.map { |line, number| [ line.chomp, number ] }
    end

    def singularize(word) = defined?(ActiveSupport::Inflector) ? ActiveSupport::Inflector.singularize(word) : word.sub(/s\z/, "")

    # ---------------------------------------------------------------- tables ---

    # Every table of db/schema.rb → owner (and its model, when it has one):
    # model tables from MODEL_OWNERS (Rails' tableize), plus the documented
    # legacy and infrastructure tables (module-boundaries.md §11, §20.1).
    NON_MODEL_TABLES = {
      "notifications" => INFRA, "product_variants" => IP, "schema_migrations" => INFRA, "ar_internal_metadata" => INFRA
    }.freeze
    INFRA_TABLE_PREFIXES = %w[solid_queue_ solid_cache_ solid_cable_ active_storage_ action_text_ action_mailbox_].freeze

    TABLE_OWNERS = MODEL_OWNERS.to_h do |model, domain|
      table = defined?(ActiveSupport::Inflector) ? ActiveSupport::Inflector.tableize(model) : "#{model.downcase}s"
      [ table, { owner: domain, model: model } ]
    end.merge(NON_MODEL_TABLES.transform_values { |domain| { owner: domain, model: nil } }).freeze

    def table_owner(table)
      return { owner: INFRA, model: nil } if INFRA_TABLE_PREFIXES.any? { |prefix| table.start_with?(prefix) }

      TABLE_OWNERS[table]
    end

    def schema_tables
      File.read(File.join(root, "db/schema.rb")).scan(/create_table "([^"]+)"/).flatten.sort
    end

    def classify(path, source, target, constant)
      return [ :allowed, nil ] if UPSTREAM.fetch(source, []).include?(target)

      entry = CLASSIFIED.find { |e| e.files.match?(path) && e.constants.match?(constant.delete_prefix("::")) }
      entry ? [ :classified, entry ] : [ :unclassified, nil ]
    end

    # Enforcement API (module-boundaries.md §20.3 D3).
    def violations(result = inventory) = result[:references].select { |r| r.status == :unclassified }

    def unused_exceptions(result = inventory)
      used = result[:references].filter_map { |r| r.exception&.id }.to_set
      CLASSIFIED.map(&:id).reject { |id| used.include?(id) }
    end

    def inventory(files = app_files)
      mapped, unmapped = files.partition { |path| domain_of_file(path) }
      { files: files, unmapped: unmapped, mapped: mapped.group_by { |path| domain_of_file(path) },
        references: mapped.flat_map { |path| references_in(path) } }
    end

    def camelize(snake) = snake.split("_").map(&:capitalize).join

    # ------------------------------------------------------------- report ---

    def report(result = inventory)
      refs = result[:references]
      grouped = refs.group_by { |r| [ r.status, r.source, r.target, r.path, r.constant, r.kind ] }
      lines = []
      lines << "# Domain dependency inventory — ENFORCED (module-boundaries.md §19 step 0, §20.3 D3)"
      lines << "# Generated by: bin/rails architecture:dependency_report  (script/architecture/dependency_inventory.rb)"
      lines << "# Enforced by: spec/architecture/dependency_inventory_spec.rb — no unclassified reference, no unmapped"
      lines << "#   app/ file, no unmapped schema table, no stale exception; exceptions: docs/architecture/dependency-exceptions.md"
      lines << "# Deterministic: sorted, no timestamps, no line numbers (counts per file and constant)."
      lines << "# Detects (static): constants in app/**/*.rb and *.erb code; association macros (class_name: or the"
      lines << "#   inflected name); table names after upper-case FROM / JOIN / INTO / UPDATE inside string literals."
      lines << "# Does NOT detect: dynamic constants (constantize, send, const_get), polymorphic / through: associations"
      lines << "#   whose name is not a model, queries built without a literal table name or with lower-case SQL keywords"
      lines << "#   (none exist today), method calls on associations,"
      lines << "#   i18n keys and other string contents, runtime behaviour. Those stay covered by the per-component"
      lines << "#   boundary specs (spec/architecture/*_boundary_spec.rb). Dotfiles (.keep) are not listed."
      lines << "# allowed = §12.1 direction; classified = a D4 exception (ID, owner, guard); unclassified = a violation."
      lines << "#"
      lines << "## Files under app/: #{result[:files].size}"
      LAYERS.each do |layer|
        lines << "#   #{layer}: #{result[:mapped].fetch(layer, []).size}"
      end
      lines << "#   unmapped: #{result[:unmapped].size}"
      lines << "#"
      lines << "## Cross-domain references (distinct file + constant / reference lines) by status"
      %i[allowed classified unclassified].each do |status|
        subset = refs.select { |r| r.status == status }
        lines << "#   #{status}: #{subset.map { |r| [ r.path, r.constant ] }.uniq.size} / #{subset.size}"
      end
      lines << "#"
      lines << "## Edges (source → target: distinct file + constant, by status)"
      refs.group_by { |r| [ r.source, r.target ] }.sort_by { |k, _| k.map(&:to_s) }.each do |(source, target), subset|
        counts = %i[allowed classified unclassified].map { |s| "#{s} #{subset.select { |r| r.status == s }.map { |r| [ r.path, r.constant ] }.uniq.size}" }
        lines << "#   #{source} → #{target}: #{counts.join(', ')}"
      end
      lines << ""
      lines << "[unmapped]"
      result[:unmapped].each { |path| lines << path }
      %i[unclassified classified].each do |status|
        lines << ""
        lines << "[#{status}]"
        grouped.select { |(s, *), _| s == status }.sort_by { |k, _| k.map(&:to_s) }.each do |(_, source, target, path, constant, _kind), group|
          suffix = status == :classified ? "  — #{group.first.reason}" : ""
          kind = group.first.kind == :constant ? "" : " (#{group.first.kind})"
          lines << "#{source} → #{target}  #{path}  #{constant}#{kind} ×#{group.size}#{suffix}"
        end
      end
      lines << ""
      lines << "[allowed]"
      grouped.select { |(s, *), _| s == :allowed }.sort_by { |k, _| k.map(&:to_s) }.each do |(_, source, target, path, constant, kind), group|
        lines << "#{source} → #{target}  #{path}  #{constant}#{kind == :constant ? '' : " (#{kind})"} ×#{group.size}"
      end
      "#{lines.join("\n")}\n"
    end
  end
end
