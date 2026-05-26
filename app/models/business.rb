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

  def auto_payroll_enabled?
    payroll_auto_generate_day.present?
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
