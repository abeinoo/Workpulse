class Notification < ApplicationRecord
  belongs_to :user
  belongs_to :notifiable, polymorphic: true, optional: true

  SEVERITIES  = %w[info warning danger success].freeze
  EVENT_TYPES = %w[
    payroll_submitted payroll_finalized payroll_paid payroll_regenerated
    payroll_auto_generated
    adjustment_approved adjustment_rejected
    line_item_approved line_item_rejected line_item_waived
    attendance_anomaly employee_request_approved employee_request_rejected
    system_warning
  ].freeze

  enum :severity, {
    info:    "info",
    warning: "warning",
    danger:  "danger",
    success: "success"
  }

  validates :event_type, inclusion: { in: EVENT_TYPES }
  validates :title,      presence: true
  validates :severity,   inclusion: { in: SEVERITIES }

  scope :unread,   -> { where(read_at: nil) }
  scope :read,     -> { where.not(read_at: nil) }
  scope :recent,   -> { order(created_at: :desc) }
  scope :for_user, ->(user) { where(user: user) }
  scope :by_severity, ->(sev) { where(severity: sev) }

  def read?   = read_at.present?
  def unread? = !read?

  after_create_commit  :expire_unread_cache
  after_update_commit  :expire_unread_cache

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
