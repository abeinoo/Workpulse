class PayrollPeriodBranchReview < ApplicationRecord
  belongs_to :payroll_period
  # No branch: the period's central review (its floating employees). A central
  # slot has no reviewer until someone completes it or requests changes.
  belongs_to :branch,   optional: true
  belongs_to :reviewer, class_name: "User", optional: true

  STATUSES = %w[pending completed changes_requested].freeze

  enum :status, { pending: "pending", completed: "completed", changes_requested: "changes_requested" }

  validates :payroll_period_id, uniqueness: { scope: :branch_id }
  validates :status, inclusion: { in: STATUSES }
  validates :reviewer, presence: { message: :required }, unless: :central?

  scope :central, -> { where(branch_id: nil) }

  # Who may complete the central review or request changes on it: holders of
  # complete_branch_review at business scope (owners included). A branch or
  # area manager reviews their branches' slots only, never the central one.
  def self.central_reviewer?(user)
    user.can?(:complete_branch_review) && user.scope_for(:complete_branch_review) == "business"
  end

  def central? = branch_id.nil?
end
