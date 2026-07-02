class PayrollAuditLog < ApplicationRecord
  belongs_to :payroll_period, optional: true
  belongs_to :actor, class_name: "User"

  ACTION_TYPES = %w[generated regenerated submitted_for_review branch_review_completed branch_changes_requested resubmitted_for_review finalized paid deleted reopened adjustment_added adjustment_approved adjustment_rejected adjustment_removed adjustment_edited line_item_waived overtime_overridden deduction_waived deduction_restored].freeze

  enum :action_type, {
    generated:                 "generated",
    regenerated:               "regenerated",
    submitted_for_review:      "submitted_for_review",
    branch_review_completed:   "branch_review_completed",
    branch_changes_requested:  "branch_changes_requested",
    resubmitted_for_review:    "resubmitted_for_review",
    finalized:                 "finalized",
    paid:                      "paid",
    deleted:                   "deleted",
    reopened:                  "reopened",
    adjustment_added:          "adjustment_added",
    adjustment_approved:       "adjustment_approved",
    adjustment_rejected:       "adjustment_rejected",
    adjustment_removed:        "adjustment_removed",
    adjustment_edited:         "adjustment_edited",
    line_item_waived:          "line_item_waived",
    overtime_overridden:       "overtime_overridden",
    deduction_waived:          "deduction_waived",
    deduction_restored:        "deduction_restored"
  }

  validates :action_type, inclusion: { in: ACTION_TYPES }

  def metadata_hash
    return {} if metadata.blank?
    JSON.parse(metadata)
  rescue JSON::ParserError
    {}
  end
end
