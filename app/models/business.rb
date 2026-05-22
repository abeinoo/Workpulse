class Business < ApplicationRecord
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
  validates :max_late_permission_minutes,
            numericality: { only_integer: true, greater_than: 0 }, allow_nil: true
  validates :max_early_leave_permission_minutes,
            numericality: { only_integer: true, greater_than: 0 }, allow_nil: true

  def timezone_object
    ActiveSupport::TimeZone[timezone] || ActiveSupport::TimeZone["UTC"]
  end

  private

  def timezone_recognized
    return if timezone.blank?
    errors.add(:timezone, "is not a recognized timezone") unless ActiveSupport::TimeZone[timezone]
  end
end
