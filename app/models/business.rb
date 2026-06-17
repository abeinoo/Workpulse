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
  has_many :stock_issues,         dependent: :destroy
  has_many :stock_transfers,      dependent: :destroy
  has_many :stock_adjustments,    dependent: :destroy
  has_many :stock_counts,         dependent: :destroy
  has_many :inventory_movements,  dependent: :destroy

  has_many :departments,              dependent: :destroy
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
  has_many :custody_transactions,  dependent: :destroy
  has_many :branch_revenues,       dependent: :destroy

  serialize :settings, coder: JSON

  validates :name,                presence: true
  validates :timezone,            presence: true
  validate  :timezone_recognized
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

  private

  def timezone_recognized
    return if timezone.blank?
    errors.add(:timezone, "is not a recognized timezone") unless ActiveSupport::TimeZone[timezone]
  end
end
