class AttendanceRecord < ApplicationRecord
  belongs_to :user
  belongs_to :branch,           optional: true
  belongs_to :shift_assignment, optional: true
  belongs_to :created_by, class_name: "User", optional: true
  belongs_to :updated_by, class_name: "User", optional: true
  has_many   :attendance_adjustments, dependent: :destroy
  has_many   :biometric_punch_logs, dependent: :destroy

  STATUSES = %w[incomplete present late early_leave absent].freeze
  SOURCES  = %w[mobile biometric_device import admin_manual api].freeze

  enum :status, {
    incomplete:  "incomplete",
    present:     "present",
    late:        "late",
    early_leave: "early_leave",
    absent:      "absent"
  }

  validates :user, :date, :check_in_at, :work_date, presence: true
  validates :work_date, uniqueness: { scope: :user_id, message: "already has an attendance record" }
  validates :worked_minutes, :late_minutes, :early_leave_minutes,
            numericality: { greater_than_or_equal_to: 0 }, allow_nil: true

  scope :for_date,   ->(date) { where(date: date) }
  scope :for_period, ->(from, to) { where(work_date: from..to) }
  scope :incomplete, -> { where(status: "incomplete") }
  scope :for_business, ->(business) {
    joins(:user).where(users: { business_id: business.id })
  }

  def shift
    shift_assignment&.shift
  end

  def checked_out?
    check_out_at.present?
  end

  def overnight?
    return false unless check_out_at.present?
    tz = branch&.business&.timezone_object || user.business.timezone_object
    check_out_at.in_time_zone(tz).to_date > work_date
  end

  def total_penalty_minutes
    late_minutes.to_i + early_leave_minutes.to_i
  end

  # Returns the effective source for display: check_in_source preferred, falls back to check_out_source.
  # Returns nil for legacy records created before source tracking was added.
  def primary_source
    check_in_source.presence || check_out_source.presence
  end
end
