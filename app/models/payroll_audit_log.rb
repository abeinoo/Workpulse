class PayrollAuditLog < ApplicationRecord
  belongs_to :payroll_period, optional: true
  belongs_to :actor, class_name: "User"

  ACTION_TYPES = %w[generated regenerated submitted_for_review branch_review_completed finalized paid deleted].freeze

  enum :action_type, {
    generated:               "generated",
    regenerated:             "regenerated",
    submitted_for_review:    "submitted_for_review",
    branch_review_completed: "branch_review_completed",
    finalized:               "finalized",
    paid:                    "paid",
    deleted:                 "deleted"
  }

  validates :action_type, inclusion: { in: ACTION_TYPES }

  def metadata_hash
    return {} if metadata.blank?
    JSON.parse(metadata)
  rescue JSON::ParserError
    {}
  end
end
