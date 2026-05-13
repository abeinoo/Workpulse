class EmployeeRequest < ApplicationRecord
  belongs_to :user
  belongs_to :reviewed_by, class_name: "User", optional: true
  has_one    :advance, dependent: :destroy

  REQUEST_TYPES = %w[salary_advance late_permission early_leave].freeze
  STATUSES      = %w[pending approved rejected paid].freeze

  enum :request_type, { salary_advance: "salary_advance", late_permission: "late_permission", early_leave: "early_leave" }
  # salary advances: pending → approved (manager) → paid (accountant/admin, creates Advance)
  # other types:     pending → approved | rejected
  enum :status, { pending: "pending", approved: "approved", rejected: "rejected", paid: "paid" }

  validates :request_type, :requested_for_date, :reason, presence: true
  validates :amount, presence: true, numericality: { greater_than: 0 }, if: :salary_advance?

  before_save :derive_affects_payroll

  # Business scoping through user, not branch.
  scope :for_business, ->(business) {
    joins(:user).where(users: { business_id: business.id })
  }

  # Finds pending requests from employees who belong to any of the given branches.
  scope :pending_for_branch, ->(branch_ids) {
    joins(user: :user_branches)
      .where(user_branches: { branch_id: branch_ids }, status: "pending")
      .distinct
  }

  # Used by PenaltyCalculator: returns true when an approved request waives
  # the given penalty type for a specific user + date.
  def self.exempts?(user:, date:, type:)
    where(
      user:               user,
      requested_for_date: date,
      request_type:       type,
      status:             "approved",
      affects_payroll:    true
    ).exists?
  end

  private

  # affects_payroll is always derived from request_type — never set by the caller.
  def derive_affects_payroll
    self.affects_payroll = !salary_advance?
  end
end
