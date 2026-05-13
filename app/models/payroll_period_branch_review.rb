class PayrollPeriodBranchReview < ApplicationRecord
  belongs_to :payroll_period
  belongs_to :branch
  belongs_to :reviewer, class_name: "User"

  STATUSES = %w[pending completed].freeze

  enum :status, { pending: "pending", completed: "completed" }

  validates :payroll_period_id, uniqueness: { scope: :branch_id }
  validates :status, inclusion: { in: STATUSES }
end
