class AttendanceRecord < ApplicationRecord
  belongs_to :user
  belongs_to :branch,           optional: true
  belongs_to :shift_assignment, optional: true
  belongs_to :created_by, class_name: "User", optional: true
  belongs_to :updated_by, class_name: "User", optional: true
  belongs_to :deleted_by, class_name: "User", optional: true
  has_many   :attendance_adjustments, dependent: :destroy
  has_many   :biometric_punch_logs, dependent: :destroy

  STATUSES = %w[incomplete present late early_leave late_early_leave overtime absent].freeze
  SOURCES  = %w[mobile biometric_device import admin_manual api].freeze

  # Status groups — single source of truth for reporting/dashboards so the combined
  # status (late_early_leave) is never under-counted against late or early-leave.
  LATE_STATUSES        = %w[late late_early_leave].freeze
  EARLY_LEAVE_STATUSES = %w[early_leave late_early_leave].freeze
  # Any day the employee actually attended (the inverse of absent/incomplete).
  ATTENDED_STATUSES    = %w[present late early_leave late_early_leave overtime].freeze

  enum :status, {
    incomplete:       "incomplete",
    present:          "present",
    late:             "late",
    early_leave:      "early_leave",
    late_early_leave: "late_early_leave",
    overtime:         "overtime",
    absent:           "absent"
  }

  validates :user, :date, :check_in_at, :work_date, presence: true
  validates :work_date, uniqueness: { scope: :user_id, message: "already has an attendance record" }
  validates :worked_minutes, :late_minutes, :early_leave_minutes, :overtime_minutes,
            numericality: { greater_than_or_equal_to: 0 }, allow_nil: true

  scope :for_date,   ->(date) { where(date: date) }
  scope :for_period, ->(from, to) { where(work_date: from..to) }
  scope :incomplete, -> { where(status: "incomplete") }
  scope :for_business, ->(business) {
    joins(:user).where(users: { business_id: business.id })
  }
  scope :active,  -> { where(deleted_at: nil) }
  scope :deleted, -> { where.not(deleted_at: nil) }

  def deleted?
    deleted_at.present?
  end

  def shift
    shift_assignment&.shift
  end

  def checked_out?
    check_out_at.present?
  end

  # A payable worked day: attendance is COMPLETE (both punches present) and the
  # day is not marked absent. A single-punch/open record (no check_out) is never
  # payable — note an open *late* record carries status "late", not "incomplete",
  # so completeness must be decided by check_out_at presence, not by status.
  def complete?
    check_in_at.present? && check_out_at.present? && !absent?
  end

  def overnight?
    return false unless check_out_at.present?
    tz = branch&.business&.timezone_object || user.business.timezone_object
    check_out_at.in_time_zone(tz).to_date > work_date
  end

  def total_penalty_minutes
    late_minutes.to_i + early_leave_minutes.to_i
  end

  # True for any status that includes lateness (plain late or the combined status).
  def counts_as_late?
    LATE_STATUSES.include?(status)
  end

  # True for any status that includes an early departure (plain or combined).
  def counts_as_early_leave?
    EARLY_LEAVE_STATUSES.include?(status)
  end

  # Returns the effective source for display: check_in_source preferred, falls back to check_out_source.
  # Returns nil for legacy records created before source tracking was added.
  def primary_source
    check_in_source.presence || check_out_source.presence
  end
end
