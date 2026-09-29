# "طلب إضافة موظف" — a manager's submission of a new employee's basic personal
# data and ID photos, held here until an authorized reviewer decides on it.
#
# Personal-data verification only. There is deliberately no branch, salary,
# role, shift or payroll data on this aggregate: employment configuration is a
# separate step an administrator performs on the employee after approval.
#
# The submitted values live on immutable revisions (one per submission), and
# every decision appends an event — nothing submitted is ever overwritten.
#
#   pending_review → approved            (employee record created)
#                  → rejected            (terminal, reason required)
#                  → changes_requested → (resubmitted) pending_review → …
class EmployeeDataRequest < ApplicationRecord
  STATUSES      = %w[pending_review changes_requested approved rejected].freeze
  OPEN_STATUSES = %w[pending_review changes_requested].freeze

  belongs_to :business
  belongs_to :submitted_by, class_name: "User"
  belongs_to :reviewed_by,  class_name: "User", optional: true
  belongs_to :employee,     class_name: "User", optional: true

  has_many :revisions, -> { order(:revision_number) },
           class_name: "EmployeeDataRequestRevision", inverse_of: :employee_data_request
  has_one  :latest_revision, -> { order(revision_number: :desc) },
           class_name: "EmployeeDataRequestRevision"
  has_many :events, -> { order(:created_at, :id) },
           class_name: "EmployeeDataRequestEvent", inverse_of: :employee_data_request

  enum :status, STATUSES.index_with(&:itself), validate: true

  scope :open_requests, -> { where(status: OPEN_STATUSES) }

  # Pending review first (the reviewer's queue), then requests awaiting the
  # manager's corrections, then decided ones — newest activity first within each.
  scope :review_order, -> {
    order(Arel.sql(<<~SQL.squish)).order(updated_at: :desc)
      CASE employee_data_requests.status
        WHEN 'pending_review'    THEN 0
        WHEN 'changes_requested' THEN 1
        ELSE 2
      END
    SQL
  }

  # ── Index filters (no-ops when blank, so they compose freely) ──
  scope :with_status,       ->(status) { where(status: status) if status.present? }
  scope :submitted_by_user, ->(id)     { where(submitted_by_id: id) if id.present? }
  scope :submitted_on_or_after,  ->(date) { where(created_at: date.in_time_zone.beginning_of_day..) if date }
  scope :submitted_on_or_before, ->(date) { where(created_at: ..date.in_time_zone.end_of_day) if date }

  def decided? = approved? || rejected?

  # The most recent reviewer note (rejection reason / requested correction).
  def latest_review_event
    events.reverse.find { |e| e.action.in?(EmployeeDataRequestEvent::REVIEW_ACTIONS) }
  end
end
