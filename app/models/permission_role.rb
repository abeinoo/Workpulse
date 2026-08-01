class PermissionRole < ApplicationRecord
  belongs_to :business
  has_many   :users, dependent: :nullify

  ROLE_TYPES = %w[branch_manager area_manager accountant employee].freeze

  # Workspace controls which sidebar layout users of this role see.
  # :employee   → flat personal sidebar (attendance, shifts, requests, payroll)
  # :management → grouped management sidebar (all operational sections)
  # Intentionally independent of role_type: a "Cashier Supervisor" could have
  # role_type nil but workspace :employee, for example. The enum provides
  # employee_workspace? / management_workspace? predicates and eliminates
  # raw "employee"/"management" strings throughout the codebase.
  enum :workspace, { employee: "employee", management: "management" },
       suffix: :workspace, default: "management"

  PERMISSION_GROUPS = {
    employees:             %w[view_employees manage_employees manage_salary_profiles],
    attendance:            %w[view_attendance manage_attendance delete_attendance manage_devices],
    payroll:               %w[view_payroll view_draft_payroll view_payroll_analytics view_payroll_audit_log
                               create_payroll regenerate_payroll submit_payroll_review
                               complete_branch_review approve_payroll_items
                               manage_payroll_overrides manage_payroll_deduction_waivers
                               finalize_payroll pay_payroll reopen_payroll delete_payroll
                               pay_advances],
    adjustments:           %w[view_adjustments manage_adjustments approve_adjustments edit_approved_adjustments],
    requests:              %w[view_requests approve_requests],
    shifts:                %w[view_shifts manage_shifts assign_shifts],
    reports:               %w[view_dashboard view_reports export_reports],
    inventory:             %w[view_inventory manage_inventory view_inventory_reports
                               manage_suppliers manage_products manage_stock_receipts
                               create_goods_receipts approve_goods_receipts
                               confirm_goods_receipts void_goods_receipts
                               manage_stock_issues manage_stock_transfers
                               manage_stock_counts post_stock_counts view_stock_count_reports],
    performance:           %w[view_performance_dashboard view_notes view_monthly_reviews
                               view_performance_reports manage_evaluation_templates
                               create_observations manage_reviews finalize_reviews],
    daily_reconciliation:  %w[create_till_session
                               view_daily_reconciliation
                               view_session_totals
                               close_till_session
                               accept_till_handover
                               create_till_deposit
                               verify_daily_reconciliation
                               edit_session_totals
                               edit_day_close_amounts
                               void_till_handover
                               reverse_till_handover
                               adjust_till_handover
                               void_till_deposit
                               settle_remaining_deposit_balance
                               view_own_employee_reconciliation_summary
                               view_all_employee_reconciliation_summary
                               correct_opening_float
                               view_sales_transactions_verification
                               manage_sales_import
                               review_daily_reconciliation
                               override_review_requirement
                               manage_bank_disputes],
    finance_overview:      %w[view_finance_dashboard],
    pos_import:            %w[view_pos_import manage_pos_import],
    expenses:              %w[view_expenses create_expenses edit_expenses approve_expenses],
    expense_administration: %w[manage_expense_categories manage_expense_types
                                manage_expense_tags manage_recurring_expenses
                                manage_payment_methods],
    employee_balances:     %w[view_employee_balances manage_employee_balances
                               create_balance_requests approve_balance_requests],
    expense_reports:       %w[view_expense_reports],
    deposit_verification:  %w[view_deposit_verification
                               import_bank_statement
                               verify_deposits
                               manual_match_deposits
                               delete_import],
    settings:              %w[manage_settings manage_branches],
    obligations:           %w[manage_obligations],
    administration:        %w[manage_roles],
    # Simplified to match the active transfer-driven workflow (Towel Balances
    # -> Towel Transfers -> Dispatch -> Receipt Confirmation -> Adjustments).
    # declare_dirty_towels/dispatch_clean_towels were never checked by any
    # policy/controller — towel condition is inferred from branch_type (see
    # TowelTransfer.infer_towel_status), not declared by the user.
    # manage_laundry_batches/record_batch_consumption/complete_laundry_batches
    # protected the LaundryBatch workflow, which is deliberately not part of
    # normal navigation (see _sidebar.html.erb) — that model/controller/data
    # are preserved, just no longer reachable through the permission system
    # for non-owners (see LaundryBatchPolicy, unchanged).
    laundry_operations:    %w[view_towel_balances create_towel_transfers
                               confirm_towel_receipt adjust_towel_balances
                               configure_towel_usage_expectations],
    # Split out from laundry_operations deliberately: these expose payroll
    # cost and business-wide financial figures, which normal laundry staff
    # (granted laundry_operations) must not automatically get — mirrors how
    # finance_overview/expense_reports are split out from the base expenses
    # group for the same sensitivity reason.
    laundry_cost_reports: %w[view_laundry_consumption_reports view_laundry_cost_reports
                              manage_laundry_cost_settings]
  }.freeze

  ALL_PERMISSIONS = PERMISSION_GROUPS.values.flatten.freeze

  # Default permission sets per role archetype. Applied when a new PermissionRole
  # is created with a role_type and no permissions have been manually chosen.
  DEFAULT_PERMISSIONS_BY_ROLE_TYPE = {
    "branch_manager" => %w[
      view_dashboard view_reports
      view_expenses create_expenses
      view_employee_balances create_balance_requests
      view_employees view_attendance view_shifts assign_shifts
      view_requests view_payroll complete_branch_review
      view_adjustments
      view_performance_dashboard view_notes view_monthly_reviews
      view_daily_reconciliation review_daily_reconciliation
    ],
    "area_manager" => %w[
      view_dashboard view_reports export_reports
      view_expenses create_expenses edit_expenses approve_expenses
      view_employee_balances create_balance_requests
      view_employees manage_employees view_attendance
      view_shifts assign_shifts
      view_requests approve_requests
      view_payroll view_draft_payroll complete_branch_review
      view_adjustments approve_adjustments
      view_performance_dashboard view_notes view_monthly_reviews view_performance_reports
    ],
    "accountant" => %w[
      view_dashboard view_reports export_reports
      view_finance_dashboard
      view_expenses create_expenses edit_expenses approve_expenses
      manage_expense_categories manage_expense_types manage_expense_tags manage_recurring_expenses
      view_employee_balances manage_employee_balances create_balance_requests approve_balance_requests
      view_expense_reports
      view_payroll view_draft_payroll view_payroll_analytics view_payroll_audit_log
      view_adjustments approve_adjustments
      view_inventory view_inventory_reports view_stock_count_reports
      view_deposit_verification import_bank_statement
      view_sales_transactions_verification manage_sales_import
      view_pos_import manage_pos_import
    ],
    "employee" => %w[
      view_employee_balances create_balance_requests
      view_requests
      view_own_employee_reconciliation_summary
      view_monthly_reviews
    ]
  }.freeze

  # Permissions where "which employees?" matters — these support data scopes.
  # Global-operation permissions (settings, reports, admin) have no scope.
  #
  # Excluded from scoping:
  #   - finalize_payroll / pay_payroll / delete_payroll / reopen_payroll:
  #     period-level transitions; the period belongs to the whole business.
  #   - approve_payroll_items: a period-wide bulk action, not per-employee.
  #   - approve_adjustments / manage_devices / manage_shifts: global operations.
  #
  # complete_branch_review IS scopable — managers should be able to complete
  # reviews only for branches in their authorized scope.
  # Branch-scoped permissions: financial records (expenses, balance accounts) are
  # scoped by branch — resolved via BranchScope — rather than by employee.
  # They share the same SCOPE_OPTIONS (self/branch/area/business); the policy layer
  # picks which resolver applies. Listed separately, then merged into the canonical
  # SCOPABLE_PERMISSIONS so the role editor still renders one scope dropdown per
  # scopable permission.
  BRANCH_SCOPABLE_PERMISSIONS = %w[
    view_expenses create_expenses edit_expenses approve_expenses
    view_employee_balances
    view_deposit_verification import_bank_statement verify_deposits manual_match_deposits delete_import
    view_towel_balances create_towel_transfers confirm_towel_receipt
    view_laundry_consumption_reports
    view_pos_import manage_pos_import
  ].freeze

  # Management-level Daily Reconciliation permissions — the only DR permissions
  # that are scopable (branch/area/business) because they control cross-branch
  # data visibility. Cashier-level DR permissions (create_till_session,
  # view_session_totals, close_till_session, accept_till_handover,
  # create_till_deposit) are NOT scopable — they always operate on the current
  # branch session determined by the user's shift assignment.
  DR_MANAGEMENT_PERMISSIONS = %w[
    view_daily_reconciliation
    verify_daily_reconciliation
    edit_session_totals
    edit_day_close_amounts
    void_till_handover
    reverse_till_handover
    adjust_till_handover
    void_till_deposit
    settle_remaining_deposit_balance
    view_all_employee_reconciliation_summary
    view_sales_transactions_verification
    manage_sales_import
    review_daily_reconciliation
    manage_bank_disputes
  ].freeze

  # The Laundry permissions that are actually scopable (a subset of
  # laundry_operations/laundry_cost_reports — computed against
  # BRANCH_SCOPABLE_PERMISSIONS rather than listed again, so this stays correct
  # if a laundry permission's scopability ever changes).
  LAUNDRY_BRANCH_SCOPABLE_PERMISSIONS = (
    (PERMISSION_GROUPS[:laundry_operations] + PERMISSION_GROUPS[:laundry_cost_reports]) & BRANCH_SCOPABLE_PERMISSIONS
  ).freeze

  # Permissions where the minimum scope is "branch" — "Personal Only" (self)
  # makes no sense because these permissions always relate to a branch/laundry
  # operation, not an individual user's data. The permission form excludes
  # "self" for these, and scopes_are_valid rejects it server-side too.
  BRANCH_MINIMUM_SCOPE_PERMISSIONS = (DR_MANAGEMENT_PERMISSIONS + LAUNDRY_BRANCH_SCOPABLE_PERMISSIONS).freeze

  SCOPABLE_PERMISSIONS = (
    PERMISSION_GROUPS.slice(:employees, :attendance, :payroll, :adjustments, :requests, :shifts, :performance)
                     .values.flatten -
      %w[finalize_payroll pay_payroll delete_payroll reopen_payroll
         approve_payroll_items create_payroll regenerate_payroll submit_payroll_review
         view_draft_payroll view_payroll_audit_log
         approve_adjustments edit_approved_adjustments manage_devices manage_shifts
         manage_evaluation_templates view_performance_reports] +
    BRANCH_SCOPABLE_PERMISSIONS +
    DR_MANAGEMENT_PERMISSIONS
  ).freeze

  # Canonical data-scope names. Branch membership is shift-driven; "area" is a
  # first-class tier (branches under an area manager). The legacy
  # managed_employees scope has been folded into "branch".
  SCOPE_OPTIONS = %w[self branch area business].freeze

  # Legacy scope value → canonical. Applied on read (#scope_for) and normalized
  # into storage on save (before_validation) so pre-migration data keeps working
  # until the legacy names are fully removed in the final cleanup phase.
  LEGACY_SCOPE_ALIASES = {
    "self_only"              => "self",
    "branch_only"            => "branch",
    "business_wide"          => "business"
  }.freeze

  # The scope values a given permission may be assigned — every option except
  # for permissions in BRANCH_MINIMUM_SCOPE_PERMISSIONS, which exclude "self".
  # Single source of truth for both the permission-role form and
  # #scopes_are_valid, so the UI restriction and server-side validation can
  # never drift apart.
  def self.scope_options_for(perm)
    BRANCH_MINIMUM_SCOPE_PERMISSIONS.include?(perm.to_s) ? SCOPE_OPTIONS - %w[self] : SCOPE_OPTIONS
  end

  def self.normalize_scope(value)
    return nil if value.blank?

    v = value.to_s
    LEGACY_SCOPE_ALIASES.fetch(v, v)
  end

  # Permissions that require other permissions to be meaningful.
  # Granting a permission without its dependencies creates hidden authorization gaps
  # (e.g. manage_attendance without view_attendance means the user can edit but
  # can't see what they're editing). Keys are the "action" permission; values are
  # the required "view" prerequisites.
  PERMISSION_DEPENDENCIES = {
    "manage_attendance"      => %w[view_attendance],
    "delete_attendance"      => %w[manage_attendance],
    "manage_employees"       => %w[view_employees],
    "manage_salary_profiles" => %w[view_employees],
    "view_draft_payroll"     => %w[view_payroll],
    "finalize_payroll"       => %w[view_payroll],
    "view_payroll_analytics" => %w[view_payroll],
    "view_payroll_audit_log" => %w[view_payroll],
    "create_payroll"         => %w[view_payroll],
    "regenerate_payroll"     => %w[view_payroll],
    "submit_payroll_review"  => %w[view_payroll],
    "complete_branch_review" => %w[view_payroll],
    "approve_payroll_items"  => %w[view_payroll],
    "manage_payroll_overrides" => %w[view_payroll],
    "manage_payroll_deduction_waivers" => %w[view_payroll],
    "pay_payroll"            => %w[view_payroll],
    "reopen_payroll"         => %w[view_payroll],
    "delete_payroll"         => %w[view_payroll],
    "pay_advances"           => %w[view_requests],
    "manage_adjustments"          => %w[view_adjustments],
    "approve_adjustments"         => %w[view_adjustments],
    "edit_approved_adjustments"   => %w[manage_adjustments],
    "approve_requests"       => %w[view_requests],
    "assign_shifts"          => %w[view_shifts],
    "create_till_deposit"    => %w[close_till_session],
    "view_session_totals"    => %w[view_daily_reconciliation],
    "verify_daily_reconciliation" => %w[view_daily_reconciliation],
    "edit_session_totals"    => %w[view_daily_reconciliation],
    "edit_day_close_amounts" => %w[view_daily_reconciliation],
    "void_till_handover"     => %w[view_daily_reconciliation],
    "reverse_till_handover"  => %w[view_daily_reconciliation],
    "adjust_till_handover"   => %w[view_daily_reconciliation],
    "void_till_deposit"                => %w[view_daily_reconciliation],
    "correct_opening_float"            => %w[view_daily_reconciliation],
    "settle_remaining_deposit_balance"            => %w[view_daily_reconciliation],
    "view_all_employee_reconciliation_summary"    => %w[view_daily_reconciliation],
    "view_sales_transactions_verification" => %w[view_daily_reconciliation],
    "manage_sales_import"      => %w[view_sales_transactions_verification],
    "review_daily_reconciliation"       => %w[view_daily_reconciliation],
    "override_review_requirement"       => %w[view_daily_reconciliation],
    "manage_bank_disputes"              => %w[view_daily_reconciliation],
    "manage_obligations"               => %w[view_employees],
    "manage_inventory"       => %w[view_inventory],
    "manage_suppliers"       => %w[view_inventory],
    "manage_products"        => %w[view_inventory],
    "manage_stock_receipts"  => %w[view_inventory],
    "create_goods_receipts"  => %w[view_inventory],
    "approve_goods_receipts" => %w[view_inventory],
    "confirm_goods_receipts" => %w[view_inventory],
    "void_goods_receipts"    => %w[view_inventory],
    "manage_stock_issues"    => %w[view_inventory],
    "manage_stock_transfers" => %w[view_inventory],
    "manage_stock_counts"    => %w[view_inventory],
    "post_stock_counts"      => %w[view_inventory],
    "manage_evaluation_templates" => %w[view_performance_dashboard],
    "create_observations"         => %w[view_notes],
    "manage_reviews"              => %w[view_monthly_reviews],
    "finalize_reviews"            => %w[view_monthly_reviews manage_reviews],
    "create_expenses"             => %w[view_expenses],
    "edit_expenses"               => %w[view_expenses],
    "approve_expenses"            => %w[view_expenses],
    "manage_expense_categories"   => %w[view_expenses],
    "manage_expense_types"        => %w[view_expenses],
    "manage_expense_tags"         => %w[view_expenses],
    "manage_recurring_expenses"   => %w[view_expenses],
    "manage_pos_import"           => %w[view_pos_import],
    "manage_employee_balances"    => %w[view_employee_balances],
    "create_balance_requests"     => %w[view_employee_balances],
    "approve_balance_requests"    => %w[view_employee_balances],
    "import_bank_statement"       => %w[view_deposit_verification],
    "verify_deposits"             => %w[view_deposit_verification],
    "manual_match_deposits"       => %w[verify_deposits],
    "delete_import"               => %w[import_bank_statement],
    "create_towel_transfers"      => %w[view_towel_balances],
    "confirm_towel_receipt"       => %w[view_towel_balances],
    "adjust_towel_balances"       => %w[view_towel_balances],
    "manage_laundry_cost_settings"       => %w[view_laundry_cost_reports]
  }.freeze

  # Reverse index: given a permission, which permissions depend on it?
  PERMISSION_DEPENDENTS = PERMISSION_DEPENDENCIES
    .each_with_object(Hash.new { |h, k| h[k] = [] }) do |(perm, deps), index|
      deps.each { |dep| index[dep] << perm }
    end.freeze

  before_validation do
    # Auto-fill default permissions when a role_type is set and no permissions
    # have been explicitly chosen (new role creation convenience).
    if role_type.present? && Array(permissions).reject(&:blank?).empty?
      self.permissions = DEFAULT_PERMISSIONS_BY_ROLE_TYPE.fetch(role_type, [])
    end

    self.permissions      = Array(permissions).reject(&:blank?).uniq
    self.permission_scopes = (permission_scopes || {})
      .select { |k, _| has_permission?(k) }
      .transform_values { |v| self.class.normalize_scope(v) }
      .compact
  end

  validates :name, presence: true,
                   uniqueness: { scope: :business_id, case_sensitive: false },
                   length: { maximum: 80 }
  validates :role_type, inclusion: { in: ROLE_TYPES }, allow_blank: true
  validates :business, presence: true
  validate  :permissions_are_valid
  validate  :scopes_are_valid
  validate  :dependencies_satisfied

  scope :ordered, -> { order(:name) }

  def has_permission?(perm)
    permissions.include?(perm.to_s)
  end

  # Returns the explicitly configured scope for a permission, or nil if none is set.
  # nil means "no override — fall back to the caller's hierarchy-based default."
  # This is intentionally not defaulted to business_wide: callers must handle nil
  # explicitly so that unconfigured permissions never silently grant broader access
  # than intended.
  # Returns the full set of permissions that must accompany `permission`.
  def required_permissions_for(permission)
    PERMISSION_DEPENDENCIES.fetch(permission.to_s, [])
  end

  def scope_for(permission)
    self.class.normalize_scope((permission_scopes || {})[permission.to_s].presence)
  end

  def user_count
    users.size
  end

  def permission_count
    permissions.size
  end

  private

  def permissions_are_valid
    invalid = Array(permissions) - ALL_PERMISSIONS
    errors.add(:permissions, "contains invalid values: #{invalid.join(', ')}") if invalid.any?
  end

  def dependencies_satisfied
    Array(permissions).each do |perm|
      missing = PERMISSION_DEPENDENCIES.fetch(perm, []) - permissions
      missing.each do |dep|
        errors.add(
          :permissions,
          "'#{perm}' requires '#{dep}' — please enable '#{dep}' as well"
        )
      end
    end
  end

  def scopes_are_valid
    return unless permission_scopes.is_a?(Hash)

    permission_scopes.each do |perm, scope_val|
      next if scope_val.blank?
      unless self.class.scope_options_for(perm).include?(scope_val.to_s)
        errors.add(:permission_scopes, "invalid scope '#{scope_val}' for #{perm}")
      end
    end
  end
end
