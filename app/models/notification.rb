class Notification < ApplicationRecord
  belongs_to :user
  belongs_to :notifiable, polymorphic: true, optional: true

  # Severity drives the visual priority of a notification.
  #   info    — general updates
  #   warning — needs attention soon (late arrival, forgot punch, reminders)
  #   danger  — critical / requires action (rejections, missing attendance, reopen)
  #   success — positive confirmation (approved, paid)
  # The product "priority" levels (info / warning / critical) map onto
  # info / warning / danger respectively; "success" is a positive-confirmation
  # variant of "info".
  SEVERITIES = %w[info warning danger success].freeze

  # Categories power the notification-center filter tabs.
  CATEGORIES = %w[attendance leave payroll approvals system].freeze

  EVENT_TYPES = %w[
    payroll_submitted payroll_finalized payroll_paid payroll_regenerated
    payroll_auto_generated payroll_reopened
    adjustment_approved adjustment_rejected
    line_item_approved line_item_rejected line_item_waived
    attendance_anomaly
    attendance_missing_check_in attendance_missing_check_out
    attendance_late attendance_correction_approved attendance_correction_rejected
    manager_missing_attendance manager_pending_corrections
    leave_submitted leave_approved leave_rejected leave_cancelled
    manager_leave_request
    employee_request_approved employee_request_rejected employee_request_submitted
    manager_pending_approvals
    system_warning
  ].freeze

  # Single source of truth: every event maps to a category + default severity.
  # The Notifications::Creator service consults this so callers only pass an
  # event_type. Keeps category/severity consistent across the whole app.
  EVENT_CATALOG = {
    # ── Payroll ──────────────────────────────────────────────────────────────
    "payroll_submitted"        => { category: "payroll",    severity: "info" },
    "payroll_finalized"        => { category: "payroll",    severity: "success" },
    "payroll_paid"             => { category: "payroll",    severity: "success" },
    "payroll_regenerated"      => { category: "payroll",    severity: "warning" },
    "payroll_auto_generated"   => { category: "payroll",    severity: "info" },
    "payroll_reopened"         => { category: "payroll",    severity: "danger" },
    "adjustment_approved"      => { category: "payroll",    severity: "success" },
    "adjustment_rejected"      => { category: "payroll",    severity: "warning" },
    "line_item_approved"       => { category: "payroll",    severity: "success" },
    "line_item_rejected"       => { category: "payroll",    severity: "warning" },
    "line_item_waived"         => { category: "payroll",    severity: "info" },
    # ── Attendance ───────────────────────────────────────────────────────────
    "attendance_anomaly"             => { category: "attendance", severity: "warning" },
    "attendance_missing_check_in"    => { category: "attendance", severity: "warning" },
    "attendance_missing_check_out"   => { category: "attendance", severity: "warning" },
    "attendance_late"                => { category: "attendance", severity: "warning" },
    "attendance_correction_approved" => { category: "attendance", severity: "success" },
    "attendance_correction_rejected" => { category: "attendance", severity: "danger" },
    "manager_missing_attendance"     => { category: "attendance", severity: "warning" },
    "manager_pending_corrections"    => { category: "attendance", severity: "info" },
    # ── Leave ────────────────────────────────────────────────────────────────
    "leave_submitted"      => { category: "leave",     severity: "info" },
    "leave_approved"       => { category: "leave",     severity: "success" },
    "leave_rejected"       => { category: "leave",     severity: "danger" },
    "leave_cancelled"      => { category: "leave",     severity: "info" },
    "manager_leave_request" => { category: "leave",    severity: "info" },
    # ── Approvals (generic employee requests) ────────────────────────────────
    "employee_request_submitted" => { category: "approvals", severity: "info" },
    "employee_request_approved"  => { category: "approvals", severity: "success" },
    "employee_request_rejected"  => { category: "approvals", severity: "danger" },
    "manager_pending_approvals"  => { category: "approvals", severity: "warning" },
    # ── System ───────────────────────────────────────────────────────────────
    "system_warning" => { category: "system", severity: "warning" }
  }.freeze

  enum :severity, {
    info:    "info",
    warning: "warning",
    danger:  "danger",
    success: "success"
  }

  validates :event_type, inclusion: { in: EVENT_TYPES }
  validates :title,      presence: true
  validates :severity,   inclusion: { in: SEVERITIES }
  validates :category,   inclusion: { in: CATEGORIES }, allow_nil: true

  scope :unread,      -> { where(read_at: nil) }
  scope :read,        -> { where.not(read_at: nil) }
  scope :recent,      -> { order(created_at: :desc) }
  scope :for_user,    ->(user) { where(user: user) }
  scope :by_severity, ->(sev) { where(severity: sev) }
  scope :by_category, ->(cat) { where(category: cat) }

  # Default category/severity for a given event_type (from the catalog).
  def self.category_for(event_type)
    EVENT_CATALOG.dig(event_type.to_s, :category)
  end

  def self.severity_for(event_type)
    EVENT_CATALOG.dig(event_type.to_s, :severity) || "info"
  end

  def read?   = read_at.present?
  def unread? = !read?

  after_create_commit :expire_unread_cache
  after_update_commit :expire_unread_cache

  def mark_read!
    update_column(:read_at, Time.current) unless read?
  end

  def self.mark_all_read_for!(user)
    where(user: user, read_at: nil).update_all(read_at: Time.current)
    Rails.cache.delete("notif_unread/#{user.id}")
  end

  private

  def expire_unread_cache
    Rails.cache.delete("notif_unread/#{user_id}")
  end
end
