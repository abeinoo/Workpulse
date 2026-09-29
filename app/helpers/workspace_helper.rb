# Workspace navigation — the contextual nav that turns a large module
# (Inventory, Finance, Laundry, Attendance & Shifts, Performance) into a
# workspace inside WorkPulse. Every page of a workspace (its controller
# namespace, or an explicit controller list — see workspace_key_for) is wrapped
# by layouts/_workspace, and the main sidebar shows a single entry per workspace.
#
# Each workspace is plain data (sections + groups); one partial renders it as a
# vertical rail (wide desktop) or a scrolling tab strip + "More" menu (below).
#
# Visibility: a section appears only when the user can open its page — it
# reuses that page's own gate (the Pundit index? policy, or the controller's
# permission check). Setup pages additionally keep the stricter "can manage"
# condition under which the app already linked to them.
module WorkspaceHelper
  Section   = Struct.new(:key, :label, :path, :group, :primary, :active, keyword_init: true)
  Workspace = Struct.new(:key, :title, :subtitle, :icon, :root_path, :groups, :sections, keyword_init: true)

  WORKSPACE_KEYS = %i[finance inventory laundry attendance performance].freeze
  # Shown in the main sidebar's "Workspaces" group; the others sit under Employees.
  GENERAL_WORKSPACE_KEYS  = %i[finance inventory laundry].freeze
  EMPLOYEE_WORKSPACE_KEYS = %i[attendance performance].freeze

  # Attendance & Shifts pages live across the root and admin namespaces, so the
  # workspace is defined by controller rather than by namespace.
  ATTENDANCE_CONTROLLERS = %w[
    attendance_records admin/attendance_records admin/attendance_imports
    shift_assignments admin/shift_templates
    admin/shifts admin/penalty_rules shifts
    admin/shift_rule_profiles
    admin/biometric_punch_logs
  ].freeze
  # Evaluation templates keep their admin URL but belong to Performance.
  PERFORMANCE_CONTROLLERS = %w[admin/evaluation_templates].freeze

  # Inline SVG bodies (24×24 viewBox, stroke icons).
  WORKSPACE_ICONS = {
    overview:     '<rect x="3" y="3" width="7" height="7"/><rect x="14" y="3" width="7" height="7"/><rect x="14" y="14" width="7" height="7"/><rect x="3" y="14" width="7" height="7"/>',
    items:        '<path d="M20.59 13.41l-7.17 7.17a2 2 0 0 1-2.83 0L2 12V2h10l8.59 8.59a2 2 0 0 1 0 2.82z"/><line x1="7" y1="7" x2="7.01" y2="7"/>',
    warehouses:   '<path d="M22 8.35V20a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V8.35"/><path d="M2 8.35l10-5.5 10 5.5"/><path d="M6 22V12h12v10"/>',
    suppliers:    '<path d="M1 3h15v13H1z"/><path d="M16 8h4l3 3v5h-7V8z"/><circle cx="5.5" cy="18.5" r="2.5"/><circle cx="18.5" cy="18.5" r="2.5"/>',
    purchasing:   '<circle cx="9" cy="21" r="1"/><circle cx="20" cy="21" r="1"/><path d="M1 1h4l2.68 13.39a2 2 0 0 0 2 1.61h9.72a2 2 0 0 0 2-1.61L23 6H6"/>',
    receipts:     '<path d="M12 5v14"/><path d="M19 12l-7 7-7-7"/>',
    issues:       '<path d="M12 19V5"/><path d="M5 12l7-7 7 7"/>',
    transfers:    '<polyline points="17 1 21 5 17 9"/><path d="M3 11V9a4 4 0 0 1 4-4h14"/><polyline points="7 23 3 19 7 15"/><path d="M21 13v2a4 4 0 0 1-4 4H3"/>',
    adjustments:  '<path d="M12 20h9"/><path d="M16.5 3.5a2.121 2.121 0 0 1 3 3L7 19l-4 1 1-4z"/>',
    stocktake:    '<path d="M9 11l3 3L22 4"/><path d="M21 12v7a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h11"/>',
    movements:    '<polyline points="22 12 18 12 15 21 9 3 6 12 2 12"/>',
    reports:      '<path d="M3 3v18h18"/><path d="M18 17V9"/><path d="M13 17V5"/><path d="M8 17v-3"/>',
    low_stock:    '<path d="M10.29 3.86 1.82 18a2 2 0 0 0 1.71 3h16.94a2 2 0 0 0 1.71-3L13.71 3.86a2 2 0 0 0-3.42 0Z"/><line x1="12" y1="9" x2="12" y2="13"/><line x1="12" y1="17" x2="12.01" y2="17"/>',
    out_of_stock: '<circle cx="12" cy="12" r="10"/><line x1="4.93" y1="4.93" x2="19.07" y2="19.07"/>',
    idle_stock:   '<circle cx="12" cy="12" r="10"/><polyline points="12 6 12 12 16 14"/>',
    consumption:  '<path d="M3 3v18h18"/><polyline points="7 9 11 13 15 10 21 16"/>',
    settings:     '<circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 1 1-2.83 2.83l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 1 1-4 0v-.09A1.65 1.65 0 0 0 9 19.4a1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 1 1-2.83-2.83l.06-.06A1.65 1.65 0 0 0 4.68 15a1.65 1.65 0 0 0-1.51-1H3a2 2 0 1 1 0-4h.09A1.65 1.65 0 0 0 4.6 9a1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 1 1 2.83-2.83l.06.06A1.65 1.65 0 0 0 9 4.68a1.65 1.65 0 0 0 1-1.51V3a2 2 0 1 1 4 0v.09a1.65 1.65 0 0 0 1 1.51 1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 1 1 2.83 2.83l-.06.06A1.65 1.65 0 0 0 19.4 9a1.65 1.65 0 0 0 1.51 1H21a2 2 0 1 1 0 4h-.09a1.65 1.65 0 0 0-1.51 1z"/>',
    expenses:     '<path d="M4 2v20l2-1 2 1 2-1 2 1 2-1 2 1 2-1 2 1V2l-2 1-2-1-2 1-2-1-2 1-2-1-2 1z"/><line x1="8" y1="8" x2="16" y2="8"/><line x1="8" y1="12" x2="16" y2="12"/><line x1="8" y1="16" x2="12" y2="16"/>',
    recurring:    '<polyline points="23 4 23 10 17 10"/><polyline points="1 20 1 14 7 14"/><path d="M3.51 9a9 9 0 0 1 14.85-3.36L23 10M1 14l4.64 4.36A9 9 0 0 0 20.49 15"/>',
    custody:      '<rect x="2" y="5" width="20" height="14" rx="2"/><path d="M16 12h.01"/><path d="M2 10h20"/>',
    balance_requests: '<path d="M21 15a2 2 0 0 1-2 2H7l-4 4V5a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2z"/>',
    reconciliation: '<rect x="3" y="4" width="18" height="18" rx="2" ry="2"/><line x1="16" y1="2" x2="16" y2="6"/><line x1="8" y1="2" x2="8" y2="6"/><line x1="3" y1="10" x2="21" y2="10"/><polyline points="9 16 11 18 15 14"/>',
    deposit_verification: '<path d="M12 22s8-4 8-10V5l-8-3-8 3v7c0 6 8 10 8 10z"/><polyline points="9 12 11 14 15 10"/>',
    sales_imports: '<path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/><polyline points="7 10 12 15 17 10"/><line x1="12" y1="15" x2="12" y2="3"/>',
    pos_imports:  '<rect x="2" y="3" width="20" height="14" rx="2" ry="2"/><line x1="8" y1="21" x2="16" y2="21"/><line x1="12" y1="17" x2="12" y2="21"/>',
    payment_methods: '<rect x="1" y="4" width="22" height="16" rx="2" ry="2"/><line x1="1" y1="10" x2="23" y2="10"/>',
    categories:   '<path d="M22 19a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h5l2 3h9a2 2 0 0 1 2 2z"/>',
    types:        '<polygon points="12 2 2 7 12 12 22 7 12 2"/><polyline points="2 17 12 22 22 17"/><polyline points="2 12 12 17 22 12"/>',
    tags:         '<path d="M20.59 13.41l-7.17 7.17a2 2 0 0 1-2.83 0L2 12V2h10l8.59 8.59a2 2 0 0 1 0 2.82z"/><line x1="7" y1="7" x2="7.01" y2="7"/>',
    balances:     '<line x1="12" y1="3" x2="12" y2="21"/><path d="M5 7h14"/><path d="M5 7l-3 7a3 3 0 0 0 6 0z"/><path d="M19 7l-3 7a3 3 0 0 0 6 0z"/>',
    branch_consumption: '<polyline points="22 12 18 12 15 21 9 3 6 12 2 12"/>',
    cost_summary: '<line x1="12" y1="1" x2="12" y2="23"/><path d="M17 5H9.5a3.5 3.5 0 0 0 0 7h5a3.5 3.5 0 0 1 0 7H6"/>',
    towel_types:  '<path d="M12 2.69l5.66 5.66a8 8 0 1 1-11.31 0z"/>',
    inventory:    '<path d="M21 16V8a2 2 0 0 0-1-1.73l-7-4a2 2 0 0 0-2 0l-7 4A2 2 0 0 0 3 8v8a2 2 0 0 0 1 1.73l7 4a2 2 0 0 0 2 0l7-4A2 2 0 0 0 21 16z"/><polyline points="3.27 6.96 12 12.01 20.73 6.96"/><line x1="12" y1="22.08" x2="12" y2="12"/>',
    finance:      '<path d="M20 12V8H6a2 2 0 0 1-2-2c0-1.1.9-2 2-2h12v4"/><path d="M4 6v12c0 1.1.9 2 2 2h14v-4"/><path d="M18 12a2 2 0 0 0 0 4h4v-4z"/>',
    shift_types:  '<circle cx="12" cy="12" r="10"/><polyline points="12 6 12 12 16 14"/>',
    shift_assignments: '<rect x="3" y="4" width="18" height="18" rx="2"/><line x1="16" y1="2" x2="16" y2="6"/><line x1="8" y1="2" x2="8" y2="6"/><line x1="3" y1="10" x2="21" y2="10"/><polyline points="9 16 11 18 15 14"/>',
    scheduling_rules: '<path d="M9 5H7a2 2 0 0 0-2 2v12a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V7a2 2 0 0 0-2-2h-2"/><rect x="9" y="3" width="6" height="4" rx="1"/><line x1="9" y1="12" x2="15" y2="12"/><line x1="9" y1="16" x2="13" y2="16"/>',
    attendance_logs: '<path d="M9 11l3 3L22 4"/><path d="M21 12v7a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h11"/>',
    punch_logs:   '<polyline points="22 12 18 12 15 21 9 3 6 12 2 12"/>',
    observations: '<path d="M1 12s4-8 11-8 11 8 11 8-4 8-11 8-11-8-11-8z"/><circle cx="12" cy="12" r="3"/>',
    reviews:      '<path d="M11.48 3.5l2.6 5.27 5.82.85-4.21 4.1.99 5.8L11.48 17l-5.2 2.73.99-5.8L3.06 9.62l5.82-.85z"/>',
    evaluation_templates: '<path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"/><polyline points="14 2 14 8 20 8"/><line x1="9" y1="15" x2="15" y2="15"/>',
    attendance:   '<circle cx="12" cy="12" r="10"/><polyline points="12 6 12 12 16 14"/>',
    performance:  '<path d="M11.48 3.5l2.6 5.27 5.82.85-4.21 4.1.99 5.8L11.48 17l-5.2 2.73.99-5.8L3.06 9.62l5.82-.85z"/>',
    laundry:      '<rect x="3" y="2" width="18" height="20" rx="2"/><circle cx="12" cy="13" r="5"/><line x1="7" y1="6" x2="7.01" y2="6"/><line x1="11" y1="6" x2="11.01" y2="6"/>'
  }.freeze

  # The workspace the current page belongs to, or nil outside any workspace.
  def current_workspace
    return @current_workspace if defined?(@current_workspace)

    key = current_workspace_key
    @current_workspace = key ? workspace(key) : nil
  end

  # The workspace key a controller belongs to, or nil.
  def workspace_key_for(path)
    return :attendance  if ATTENDANCE_CONTROLLERS.include?(path)
    return :performance if PERFORMANCE_CONTROLLERS.include?(path)

    namespace = path.split("/").first.to_sym
    namespace if path.include?("/") && WORKSPACE_KEYS.include?(namespace)
  end

  # Builds a workspace with only the sections the current user can open.
  # Returns nil when the user can't enter the workspace at all.
  def workspace(key)
    @workspaces ||= {}
    return @workspaces[key] if @workspaces.key?(key)

    @workspaces[key] = build_workspace(key)
  end

  def workspace_icon(key, size: 16)
    body = WORKSPACE_ICONS.fetch(key)
    # Static, developer-authored SVG markup (no user input).
    %(<svg width="#{size}" height="#{size}" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">#{body}</svg>).html_safe # rubocop:disable Rails/OutputSafety
  end

  private

  def build_workspace(key)
    config = send(:"#{key}_workspace_config")
    return nil unless config[:access]

    active_key = current_workspace_key == key ? send(:"#{key}_active_section_key") : nil
    sections = config[:sections].filter_map do |section_key, label, path, group, primary, visible|
      next unless visible

      Section.new(key: section_key, label: label, path: path, group: group,
                  primary: primary, active: section_key == active_key)
    end
    return nil if sections.empty?

    Workspace.new(key: key, title: config[:title], subtitle: config[:subtitle], icon: key,
                  root_path: sections.first.path, groups: config[:groups], sections: sections)
  end

  def current_workspace_key
    workspace_key_for(controller_path)
  end

  # ── Inventory ──────────────────────────────────────────────────────────────
  def inventory_workspace_config
    reports_access = current_user.can?(:view_inventory_reports) ||
                     current_user.can?(:view_inventory) ||
                     current_user.can?(:manage_inventory)
    {
      # Mirrors Inventory::BaseController#require_inventory_access!
      access:   reports_access,
      title:    t("nav.inventory_workspace"),
      subtitle: t("inventory.workspace.subtitle"),
      groups:   { catalog: "inventory.workspace.groups.catalog", purchasing: "inventory.workspace.groups.purchasing",
                  operations: "inventory.workspace.groups.operations", insights: "inventory.workspace.groups.insights",
                  settings: nil },
      sections: [
        # Overview: gated by Inventory::BaseController itself.
        [ :overview,    t("nav.inventory_dashboard"),         inventory_root_path,              nil,         true,  true ],
        [ :items,       t("nav.inventory_products"),          inventory_products_path,          :catalog,    true,  policy(Product).index? ],
        [ :warehouses,  t("nav.inventory_warehouses"),        inventory_warehouses_path,        :catalog,    false, policy(Warehouse).index? ],
        [ :suppliers,   t("nav.inventory_suppliers"),         inventory_suppliers_path,         :catalog,    false, policy(Supplier).index? ],
        [ :purchasing,  t("nav.inventory_purchase_requests"), inventory_purchase_requests_path, :purchasing, true,  policy(PurchaseRequest).index? ],
        [ :receipts,    t("nav.inventory_goods_receipts"),    inventory_goods_receipts_path,    :purchasing, true,  policy(GoodsReceipt).index? ],
        [ :issues,      t("nav.inventory_stock_issues"),      inventory_stock_issues_path,      :operations, true,  policy(StockIssue).index? ],
        [ :transfers,   t("nav.inventory_stock_transfers"),   inventory_stock_transfers_path,   :operations, false, policy(StockTransfer).index? ],
        [ :adjustments, t("nav.inventory_stock_adjustments"), inventory_stock_adjustments_path, :operations, false, policy(StockAdjustment).index? ],
        [ :stocktake,   t("nav.inventory_stock_counts"),      inventory_stock_counts_path,      :operations, true,  policy(StockCount).index? ],
        [ :movements,   t("nav.inventory_movements"),         inventory_movements_report_path,  :insights,   false, reports_access ],
        [ :reports,     t("nav.inventory_reports"),           inventory_reports_path,           :insights,   false, reports_access ],
        [ :settings,    t("nav.inventory_settings"),          inventory_settings_path,          :settings,   false, policy(ProductCategory).index? || policy(Brand).index? || policy(WarehouseBranchSupply).index? ]
      ]
    }
  end

  def inventory_active_section_key
    case controller_name
    when "dashboard"                                     then :overview
    when "products", "barcode_labels", "barcode_lookups" then :items
    when "warehouses"                                    then :warehouses
    when "suppliers"                                     then :suppliers
    when "purchase_requests"                             then :purchasing
    when "goods_receipts"                                then :receipts
    when "stock_issues", "stock_issue_import_batches",
         "stock_issue_import_rows"                       then :issues
    when "stock_transfers"                               then :transfers
    when "stock_adjustments"                             then :adjustments
    when "stock_counts"                                  then :stocktake
    when "reports"                                       then action_name == "movements" ? :movements : :reports
    when "settings", "brands", "product_categories", "warehouse_supplies" then :settings
    end
  end

  # ── Finance ────────────────────────────────────────────────────────────────
  def finance_workspace_config
    {
      access:   Finance::BaseController::FINANCE_PERMISSIONS.any? { |p| current_user.can?(p) },
      title:    t("nav.section_finance"),
      subtitle: t("finance.workspace.subtitle"),
      groups:   { expenses: "finance.workspace.groups.expenses", balances: "finance.workspace.groups.balances",
                  cash: "finance.workspace.groups.cash", insights: "finance.workspace.groups.insights",
                  settings: "finance.workspace.groups.settings" },
      sections: [
        [ :overview,             t("nav.finance_dashboard"),              finance_root_path,                  nil,       true,  policy(:"finance/dashboard").index? ],
        [ :expenses,             t("nav.finance_expenses"),               finance_expenses_path,              :expenses, true,  policy(Expense).index? ],
        [ :recurring,            t("finance.recurring.title"),            finance_recurring_expenses_path,    :expenses, false, policy(RecurringExpense).index? ],
        [ :custody,              t("nav.finance_custody"),                finance_custody_accounts_path,      :balances, true,  policy(CustodyAccount).index? ],
        [ :balance_requests,     t("nav.finance_balance_requests"),       finance_balance_requests_path,      :balances, true,  policy(BalanceRequest).index? ],
        [ :reconciliation,       t("nav.finance_reconciliation"),         finance_daily_reconciliations_path, :cash,     true,  policy(DailyReconciliation).index? ],
        [ :deposit_verification, t("nav.finance_deposit_verification"),   finance_deposit_verifications_path, :cash,     false, policy(:deposit_verification).index? ],
        [ :sales_imports,        t("nav.finance_sales_import"),           finance_sales_imports_path,         :cash,     false, policy(SalesImport).index? ],
        [ :pos_imports,          t("nav.finance_pos_import"),             finance_pos_imports_path,           :cash,     false, policy(PosImport).index? ],
        # Mirrors Finance::ReportsController#require_reports_access!
        [ :reports,              t("nav.finance_reports"),                finance_reports_path,               :insights, false, current_user.can?(:view_expense_reports) ],
        # Setup pages — shown to those who manage them, as the Expenses and
        # Daily Reconciliation pages already did.
        [ :categories,           t("finance.categories.title"),           finance_expense_categories_path,    :settings, false, policy(ExpenseCategory).create? ],
        [ :types,                t("finance.types.title"),                finance_expense_types_path,         :settings, false, policy(ExpenseType).create? ],
        [ :tags,                 t("finance.tags.title"),                 finance_expense_tags_path,          :settings, false, policy(ExpenseTag).create? ],
        [ :payment_methods,      t("nav.finance_payment_methods"),        finance_payment_methods_path,       :settings, false, policy(PaymentMethod).create? ]
      ]
    }
  end

  def finance_active_section_key
    case controller_name
    when "dashboard"                                   then :overview
    when "expenses", "expense_payments"                then :expenses
    when "recurring_expenses"                          then :recurring
    when "custody_accounts", "custody_transactions"    then :custody
    when "balance_requests"                            then :balance_requests
    when "daily_reconciliations",
         "remaining_deposit_balances"                  then :reconciliation
    when "deposit_verifications", "bank_statements",
         "bank_statement_transactions", "bank_disputes" then :deposit_verification
    when "sales_imports"                               then :sales_imports
    when "pos_imports"                                 then :pos_imports
    when "reports"                                     then :reports
    when "expense_categories"                          then :categories
    when "expense_types"                               then :types
    when "expense_tags"                                then :tags
    when "payment_methods"                             then :payment_methods
    end
  end

  # ── Laundry ────────────────────────────────────────────────────────────────
  def laundry_workspace_config
    {
      access:   Laundry::BaseController::LAUNDRY_PERMISSIONS.any? { |p| current_user.can?(p) },
      title:    t("nav.section_laundry"),
      subtitle: t("laundry.workspace.subtitle"),
      groups:   { operations: "laundry.workspace.groups.operations", monitoring: "laundry.workspace.groups.monitoring",
                  settings: "laundry.workspace.groups.settings" },
      sections: [
        # Overview: gated by Laundry::BaseController itself.
        [ :overview,           t("nav.laundry_dashboard"),          laundry_root_path,                       nil,         true,  true ],
        [ :transfers,          t("nav.laundry_transfers"),          laundry_towel_transfers_path,            :operations, true,  policy(TowelTransfer).index? ],
        # Mirrors Laundry::TowelBalancesController#index's own check.
        [ :balances,           t("nav.laundry_balances"),           laundry_towel_balances_path,             :operations, true,  current_user.can?(:view_towel_balances) ],
        [ :adjustments,        t("nav.laundry_adjustments"),        laundry_towel_adjustments_path,          :operations, true,  policy(TowelAdjustment).index? ],
        # Mirror the report controllers' require_reports_access! checks.
        [ :branch_consumption, t("nav.laundry_branch_consumption"), laundry_reports_branch_consumption_path, :monitoring, true,  current_user.can?(:view_laundry_consumption_reports) ],
        [ :cost_summary,       t("nav.laundry_cost_summary"),       laundry_reports_cost_summary_path,       :monitoring, false, current_user.can?(:view_laundry_cost_reports) ],
        # Setup page — shown to those who configure towel types, as before.
        [ :towel_types,        t("nav.laundry_towel_types"),        laundry_towel_types_path,                :settings,   false, policy(TowelType).create? ]
      ]
    }
  end

  # Laundry batches are deliberately not in the nav (reachable by direct URL
  # only — see Laundry::LaundryBatchesController); they map to no section.
  def laundry_active_section_key
    case controller_path
    when "laundry/dashboard"                           then :overview
    when "laundry/towel_transfers"                     then :transfers
    when "laundry/towel_balances"                      then :balances
    when "laundry/towel_adjustments"                   then :adjustments
    when "laundry/reports/branch_consumption"          then :branch_consumption
    when "laundry/reports/cost_summary"                then :cost_summary
    when "laundry/towel_types", "laundry/standard_cost_rates" then :towel_types
    end
  end

  # ── Attendance & Shifts ────────────────────────────────────────────────────
  # Section gates are the exact checks the main sidebar used for these links.
  # These pages double as "My attendance" / "My shifts" for staff, so the
  # workspace chrome is limited to users with the management sidebar.
  def attendance_workspace_config
    {
      access:   current_user.management_sidebar?,
      title:    t("nav.section_attendance_shifts"),
      subtitle: t("attendance.workspace.subtitle"),
      groups:   { attendance: "attendance.workspace.groups.attendance", scheduling: "attendance.workspace.groups.scheduling",
                  devices: "attendance.workspace.groups.devices" },
      sections: [
        [ :attendance_logs,   t("nav.attendance_logs"),     attendance_records_path,         :attendance, true,  current_user.can?(:view_attendance) ],
        [ :shift_assignments, t("nav.shift_assignments"),   shift_assignments_path,          :scheduling, true,  current_user.can?(:assign_shifts) ],
        [ :shift_types,       t("nav.shift_types"),         admin_shifts_path,               :scheduling, true,  current_user.can?(:manage_shifts) ],
        [ :scheduling_rules,  t("nav.shift_rule_profiles"), admin_shift_rule_profiles_path,  :scheduling, false, current_user.can?(:manage_shifts) ],
        [ :punch_logs,        t("nav.punch_logs"),          admin_biometric_punch_logs_path, :devices,    false, current_user.can?(:manage_devices) ]
      ]
    }
  end

  def attendance_active_section_key
    case controller_path
    when "attendance_records", "admin/attendance_records",
         "admin/attendance_imports"                          then :attendance_logs
    when "shift_assignments", "admin/shift_templates"        then :shift_assignments
    when "admin/shifts", "admin/penalty_rules", "shifts"     then :shift_types
    when "admin/shift_rule_profiles"                         then :scheduling_rules
    when "admin/biometric_punch_logs"                        then :punch_logs
    end
  end

  # ── Performance ────────────────────────────────────────────────────────────
  # Staff reach their own reviews via "My reviews"; like Attendance, the
  # workspace chrome is for users with the management sidebar.
  def performance_workspace_config
    {
      access:   current_user.management_sidebar?,
      title:    t("nav.section_performance"),
      subtitle: t("performance.workspace.subtitle"),
      groups:   { evaluation: "performance.workspace.groups.evaluation", insights: "performance.workspace.groups.insights",
                  settings: "performance.workspace.groups.settings" },
      sections: [
        # Mirrors Performance::DashboardController#require_dashboard_access!
        [ :overview,             t("nav.performance_dashboard"),    performance_root_path,           nil,         true,  current_user.can?(:view_performance_dashboard) ],
        [ :observations,         t("nav.performance_observations"), performance_observations_path,   :evaluation, true,  current_user.can?(:view_notes) || current_user.can?(:create_observations) ],
        [ :reviews,              t("nav.performance_reviews"),      performance_reviews_path,        :evaluation, true,
          current_user.can?(:view_monthly_reviews) || current_user.can?(:manage_reviews) || current_user.can?(:finalize_reviews) ],
        # Mirrors Performance::ReportsController#require_reports_access!
        [ :reports,              t("nav.performance_reports"),      performance_reports_path,        :insights,   false, current_user.can?(:view_performance_reports) ],
        [ :evaluation_templates, t("nav.evaluation_templates"),     admin_evaluation_templates_path, :settings,   false, current_user.can?(:manage_evaluation_templates) ]
      ]
    }
  end

  def performance_active_section_key
    case controller_path
    when "performance/dashboard"      then :overview
    when "performance/observations"   then :observations
    when "performance/reviews"        then :reviews
    when "performance/reports"        then :reports
    when "admin/evaluation_templates" then :evaluation_templates
    end
  end
end
