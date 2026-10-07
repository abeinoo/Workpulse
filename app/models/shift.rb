class Shift < ApplicationRecord
  belongs_to :business
  # Penalty rules are owned by Attendance & Payroll; the shift form stages them
  # through Shifts::PenaltyRuleSettings. autosave: staged rules are validated and
  # saved (or destroyed) with the shift, in its transaction.
  has_many :penalty_rules,     dependent: :destroy, autosave: true
  has_many :shift_assignments, dependent: :restrict_with_error

  SHIFT_TYPES = %w[fixed_time hour_based].freeze

  enum :shift_type, { fixed_time: "fixed_time", hour_based: "hour_based" }

  validates :name, :shift_type, :business, presence: true
  validates :name, uniqueness: { scope: :business_id }
  validates :start_time, :end_time, presence: true, if: :fixed_time?
  validates :required_hours,
            presence: true,
            numericality: { greater_than: 0 },
            if: :hour_based?

  # A blank overtime_rate_multiplier means overtime is disabled for this shift.
  validates :overtime_rate_multiplier,
            numericality: { greater_than_or_equal_to: 1 }, allow_nil: true
  validates :max_late_permission_minutes,
            numericality: { only_integer: true, greater_than: 0 }, allow_nil: true
  validates :max_early_leave_permission_minutes,
            numericality: { only_integer: true, greater_than: 0 }, allow_nil: true

  scope :active,        -> { where(active: true) }
  scope :for_business,  ->(business) { where(business: business) }

  # Overtime is disabled when the multiplier is blank (NULL).
  def overtime_enabled?
    overtime_rate_multiplier.present?
  end

  def overnight?
    fixed_time? && start_time && end_time && end_time < start_time
  end

  # True only when both clock times are present — guards callers from nil.hour.
  def timed?
    start_time.present? && end_time.present?
  end

  def duration_minutes
    return required_hours * 60 if hour_based?
    return unless start_time && end_time

    mins = ((end_time - start_time) / 60).to_i
    overnight? ? mins + (24 * 60) : mins
  end
end
