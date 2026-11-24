class Business < ApplicationRecord
  include Attachable

  has_one_attached :logo
  has_one_attached :stamp_image

  validates_attachment :logo,
    content_types: Attachable::LOGO_CONTENT_TYPES,
    max_size:      Attachable::DEFAULT_LOGO_SIZE

  validates_attachment :stamp_image,
    content_types: Attachable::IMAGE_CONTENT_TYPES,
    max_size:      Attachable::DEFAULT_MAX_SIZE

  CURRENCIES = {
    "SAR" => { name: "Saudi Riyal",     symbol: "ر.س", symbol_en: "SAR" },
    "EGP" => { name: "Egyptian Pound",  symbol: "ج.م", symbol_en: "EGP" },
    "AED" => { name: "UAE Dirham",      symbol: "د.إ", symbol_en: "AED" },
    "USD" => { name: "US Dollar",       symbol: "$",   symbol_en: "$"   },
    "EUR" => { name: "Euro",            symbol: "€",   symbol_en: "€"   },
    "GBP" => { name: "British Pound",   symbol: "£",   symbol_en: "£"   },
    "KWD" => { name: "Kuwaiti Dinar",   symbol: "د.ك", symbol_en: "KWD" },
    "BHD" => { name: "Bahraini Dinar",  symbol: "د.ب", symbol_en: "BHD" },
    "QAR" => { name: "Qatari Riyal",    symbol: "ر.ق", symbol_en: "QAR" },
    "OMR" => { name: "Omani Rial",      symbol: "ر.ع", symbol_en: "OMR" },
    "JOD" => { name: "Jordanian Dinar", symbol: "د.أ", symbol_en: "JOD" },
  }.freeze

  belongs_to :owner, class_name: "User", optional: true

  has_many :branches,              dependent: :destroy
  has_many :users,                 dependent: :destroy
  has_many :permission_roles,      dependent: :destroy
  has_many :employee_obligations,  dependent: :destroy
  has_many :shifts,               dependent: :destroy
  has_many :payroll_periods,      dependent: :destroy
  has_many :biometric_devices,    dependent: :destroy
  has_many :biometric_punch_logs, dependent: :destroy

  has_many :warehouses,           dependent: :destroy
  has_many :suppliers,            dependent: :destroy
  has_many :brands,               dependent: :destroy
  has_many :product_categories,   dependent: :destroy
  has_many :products,             dependent: :destroy
  has_many :goods_receipts,       dependent: :destroy
  has_many :purchase_requests,    dependent: :destroy
  has_many :stock_issues,         dependent: :destroy
  has_many :stock_transfers,      dependent: :destroy
  has_many :stock_adjustments,    dependent: :destroy
  has_many :stock_counts,         dependent: :destroy
  has_many :inventory_movements,  dependent: :destroy
  has_many :stock_issue_import_batches, dependent: :destroy

  # Laundry Operations
  has_many :towel_types,             dependent: :destroy
  has_many :towel_ledger_entries,    dependent: :destroy
  has_many :towel_transfers,         dependent: :destroy
  has_many :laundry_batches,         dependent: :destroy
  has_many :towel_adjustments,       dependent: :destroy
  has_many :services,                dependent: :destroy
  has_many :laundry_standard_cost_rates, dependent: :destroy

  has_many :departments,              dependent: :destroy
  has_many :job_titles,               dependent: :destroy
  has_many :evaluation_templates,     dependent: :destroy
  has_many :performance_reviews,      dependent: :destroy
  has_many :performance_observations, dependent: :destroy

  # Financial Operations & Expense Management
  has_many :expense_categories,    dependent: :destroy
  has_many :expense_types,         dependent: :destroy
  has_many :expense_tags,          dependent: :destroy
  has_many :expenses,              dependent: :destroy
  has_many :balance_requests,      dependent: :destroy
  has_many :recurring_expenses,    dependent: :destroy
  has_many :custody_accounts,      dependent: :destroy
  has_many :employee_insurance_profiles, dependent: :destroy
  has_many :custody_transactions,  dependent: :destroy
  has_many :branch_revenues,       dependent: :destroy
  has_many :sales_imports,         dependent: :destroy
  has_many :pos_imports,           dependent: :destroy
  has_many :pos_terminals,         dependent: :destroy
  has_many :bank_statements,       dependent: :destroy

  serialize :settings, coder: JSON

  # settings is ONE serialized column, so a save writes the whole hash from this
  # object's copy. Without these, a copy read before a concurrent change (another
  # admin's save, or the warehouse access mode switch) would silently put back
  # the old values of keys it never touched. See #merge_settings_onto_stored.
  before_create :drop_unauthorized_warehouse_access_mode
  before_update :merge_settings_onto_stored, if: :will_save_change_to_settings?
  after_save    :finish_warehouse_access_mode_write

  validates :name,                presence: true
  validates :timezone,            presence: true
  validate  :timezone_recognized
  validate  :attendance_duration_thresholds_ordered
  validates :working_days_per_month,
            numericality: { greater_than: 0, less_than_or_equal_to: 31 }
  validates :business_day_start_hour,
            numericality: { only_integer: true, greater_than_or_equal_to: 0, less_than_or_equal_to: 23 }
  validates :default_locale, inclusion: { in: %w[en ar] }, allow_blank: true

  validates :currency, inclusion: { in: CURRENCIES.keys }, allow_blank: false
  validates :max_salary_advance_percentage,
            numericality: { greater_than: 0, less_than_or_equal_to: 100 }, allow_nil: true
  validates :overtime_grace_minutes,
            numericality: { only_integer: true, greater_than_or_equal_to: 0, less_than_or_equal_to: 480 }
  validates :payroll_auto_generate_day,
            numericality: { only_integer: true, greater_than_or_equal_to: 1, less_than_or_equal_to: 28 },
            allow_nil: true
  validates :payroll_cutoff_day,
            numericality: { only_integer: true, greater_than_or_equal_to: 0, less_than_or_equal_to: 28 }
  validates :employee_code_start,
            numericality: { only_integer: true, greater_than_or_equal_to: 1 }
  validates :barcode_next_number,
            numericality: { only_integer: true, greater_than_or_equal_to: 1 }
  validates :barcode_prefix, length: { maximum: 10 }, allow_blank: true

  def auto_payroll_enabled?
    payroll_auto_generate_day.present?
  end

  # Returns the next employee_code to assign within this business, as an integer.
  #
  # Based on the *highest existing numeric* employee_code (not the employee
  # count), so gaps are preserved and codes never collide. Non-numeric legacy
  # codes (e.g. "EMP-001") are ignored when computing the maximum. The result is
  # never below the configured starting number, so:
  #   - no codes yet, start = 500             -> 500
  #   - existing 500, 501, 700, start = 500   -> 701
  #   - existing 100, start = 500             -> 500
  #
  # Generation is made race-safe by the caller (User#assign_employee_code), which
  # holds a per-business advisory lock while this runs and the row is inserted.
  def next_employee_code
    highest = users
                .where("employee_code ~ ?", '^[0-9]+$')
                .maximum(Arel.sql("employee_code::bigint"))
    [ highest.to_i + 1, employee_code_start.to_i ].max
  end

  def timezone_object
    ActiveSupport::TimeZone[timezone] || ActiveSupport::TimeZone["UTC"]
  end

  def currency_info
    CURRENCIES[currency] || CURRENCIES["SAR"]
  end

  def currency_symbol
    currency_info[:symbol]
  end

  def currency_symbol_en
    currency_info[:symbol_en]
  end

  # ── Finance settings (stored in JSON settings column) ──────────────────────
  FINANCE_SETTING_DEFAULTS = {
    "finance_overdue_days"             => 3,
    "finance_allow_partial_settlement" => true,
    "finance_max_write_off_amount"     => nil,
    "finance_notify_thresholds"        => "3,7,14"
  }.freeze

  def finance_overdue_days
    (settings || {}).fetch("finance_overdue_days", FINANCE_SETTING_DEFAULTS["finance_overdue_days"]).to_i.clamp(1, 90)
  end

  def finance_overdue_days=(val)
    self.settings = (settings || {}).merge("finance_overdue_days" => val.to_i)
  end

  def finance_allow_partial_settlement
    (settings || {}).fetch("finance_allow_partial_settlement", FINANCE_SETTING_DEFAULTS["finance_allow_partial_settlement"])
  end

  def finance_allow_partial_settlement=(val)
    self.settings = (settings || {}).merge("finance_allow_partial_settlement" => ActiveModel::Type::Boolean.new.cast(val))
  end

  def finance_allow_partial_settlement?
    finance_allow_partial_settlement != false
  end

  def finance_max_write_off_amount
    v = (settings || {}).fetch("finance_max_write_off_amount", nil)
    v.present? ? v.to_d : nil
  end

  def finance_max_write_off_amount=(val)
    self.settings = (settings || {}).merge("finance_max_write_off_amount" => val.presence)
  end

  def finance_notify_thresholds
    raw = (settings || {}).fetch("finance_notify_thresholds", FINANCE_SETTING_DEFAULTS["finance_notify_thresholds"])
    raw.to_s.split(",").map(&:strip).filter_map { |n| n.to_i if n.to_i > 0 }.sort
  end

  def finance_notify_thresholds=(val)
    self.settings = (settings || {}).merge("finance_notify_thresholds" => val.to_s.strip)
  end

  # ── Attendance duration review thresholds (JSON settings column) ──────────
  # A worked duration above these flags the attendance record for review; the
  # record itself is never modified. Hours, whole numbers.
  ATTENDANCE_SETTING_DEFAULTS = {
    "attendance_suspicious_duration_hours" => 16,
    "attendance_critical_duration_hours"   => 24
  }.freeze

  def attendance_suspicious_duration_hours
    attendance_setting("attendance_suspicious_duration_hours").clamp(1, 72)
  end

  def attendance_suspicious_duration_hours=(val)
    self.settings = (settings || {}).merge("attendance_suspicious_duration_hours" => val.to_i)
  end

  def attendance_critical_duration_hours
    attendance_setting("attendance_critical_duration_hours").clamp(1, 72)
  end

  def attendance_critical_duration_hours=(val)
    self.settings = (settings || {}).merge("attendance_critical_duration_hours" => val.to_i)
  end

  # ── Warehouse access mode (JSON settings column) ─────────────────────────
  # Per-business switch from the legacy warehouse access rule (a non-owner with
  # no warehouse assignment reaches every warehouse) to fail-closed resolution
  # through OrganizationAccess::WarehouseAccessProvider (User#inventory_warehouse_ids).
  # Only a stored JSON `true` turns it on: absent, false or any other value keeps
  # the legacy rule. No attribute setter: the one writer is the audited
  # OrganizationAccess::WarehouseAccessMode service, through
  # #assign_warehouse_access_mode (pinned by the architecture spec). Every other
  # save — however the hash was edited, however stale the copy — keeps the
  # stored value (#merge_settings_onto_stored).
  WAREHOUSE_ACCESS_FAIL_CLOSED_SETTING = "warehouse_access_fail_closed".freeze

  def warehouse_access_fail_closed?
    (settings || {})[WAREHOUSE_ACCESS_FAIL_CLOSED_SETTING] == true
  end

  # For OrganizationAccess::WarehouseAccessMode only: stage the mode for the
  # next save (which that service performs under the business row lock).
  def assign_warehouse_access_mode(fail_closed)
    @warehouse_access_mode_write = true
    key = WAREHOUSE_ACCESS_FAIL_CLOSED_SETTING
    self.settings = (settings || {}).merge(key => fail_closed)
  end

  # ── Stock Issue workflow settings (JSON settings column) ─────────────────
  # Independent per workflow (never one global self-approval setting). Like
  # the warehouse access mode, these keys have no attribute setter and are
  # kept from the stored hash on every other save (#merge_settings_onto_stored);
  # the one writer is the audited, owner-only
  # OrganizationAccess::StockIssueWorkflowSettings.
  #
  #   stock_issue_self_approval — Standard Stock Issue: "forbidden" (default,
  #     today's rule: the submitter may not approve their own submission) or
  #     "allowed".
  #   quick_issue_enabled — Quick Issue for employees holding quick_issue_stock:
  #     enabled unless a stored JSON false (default = today's behaviour). The
  #     owner may use Quick Issue either way.
  STOCK_ISSUE_SELF_APPROVAL_SETTING = "stock_issue_self_approval".freeze
  STOCK_ISSUE_SELF_APPROVAL_VALUES  = %w[forbidden allowed].freeze
  QUICK_ISSUE_ENABLED_SETTING       = "quick_issue_enabled".freeze
  STOCK_ISSUE_WORKFLOW_SETTINGS     = [ STOCK_ISSUE_SELF_APPROVAL_SETTING, QUICK_ISSUE_ENABLED_SETTING ].freeze

  def stock_issue_self_approval
    value = (settings || {})[STOCK_ISSUE_SELF_APPROVAL_SETTING]
    STOCK_ISSUE_SELF_APPROVAL_VALUES.include?(value) ? value : "forbidden"
  end

  def stock_issue_self_approval_allowed? = stock_issue_self_approval == "allowed"

  def quick_issue_enabled? = (settings || {})[QUICK_ISSUE_ENABLED_SETTING] != false

  # For OrganizationAccess::StockIssueWorkflowSettings only: stage the values
  # for the next save (which that service performs under the business row lock).
  def assign_stock_issue_workflow_settings(self_approval:, quick_issue_enabled:)
    @stock_issue_workflow_write = true
    self.settings = (settings || {}).merge(STOCK_ISSUE_SELF_APPROVAL_SETTING => self_approval,
                                           QUICK_ISSUE_ENABLED_SETTING => quick_issue_enabled)
  end

private

# Applies only the settings keys THIS copy changed onto the stored hash, read
# under a row lock inside the save's transaction — so a concurrent save of
# other keys is kept, and a concurrent mode switch (which takes the same lock)
# is either seen here or waits for this save. The warehouse access mode always
# comes from the stored hash unless #assign_warehouse_access_mode staged it.
def merge_settings_onto_stored
  original = attribute_in_database(:settings) || {}
  desired  = settings || {}
  changed  = desired.reject { |key, value| original.key?(key) && original[key] == value }
  removed  = original.keys - desired.keys
  stored   = self.class.lock.where(id: id).pick(:settings) || {}

  merged = stored.merge(changed).except(*removed)
  unless @warehouse_access_mode_write
    key = WAREHOUSE_ACCESS_FAIL_CLOSED_SETTING
    stored.key?(key) ? merged[key] = stored[key] : merged.delete(key)
  end
  unless @stock_issue_workflow_write
    STOCK_ISSUE_WORKFLOW_SETTINGS.each do |key|
      stored.key?(key) ? merged[key] = stored[key] : merged.delete(key)
    end
  end
  self.settings = merged
end

# A new business never starts fail-closed except through the mode service,
# and never starts with Stock Issue workflow settings except through theirs.
def drop_unauthorized_warehouse_access_mode
  return if settings.blank?

  dropped = []
  dropped << WAREHOUSE_ACCESS_FAIL_CLOSED_SETTING unless @warehouse_access_mode_write
  dropped.concat(STOCK_ISSUE_WORKFLOW_SETTINGS) unless @stock_issue_workflow_write
  self.settings = settings.except(*dropped)
end

def finish_warehouse_access_mode_write
  @warehouse_access_mode_write = false
  @stock_issue_workflow_write  = false
end

def attendance_setting(key)
  (settings || {}).fetch(key, ATTENDANCE_SETTING_DEFAULTS[key]).to_i
end

def attendance_duration_thresholds_ordered
  return if attendance_critical_duration_hours > attendance_suspicious_duration_hours

  errors.add(:attendance_critical_duration_hours, :greater_than,
             count: attendance_suspicious_duration_hours)
end

def timezone_recognized
    return if timezone.blank?
    errors.add(:timezone, "is not a recognized timezone") unless ActiveSupport::TimeZone[timezone]
  end
end
