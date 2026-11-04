class PayrollAuditLog < ApplicationRecord
  belongs_to :payroll_period, optional: true
  belongs_to :actor, class_name: "User"

  ACTION_TYPES = %w[generated regenerated submitted_for_review branch_review_completed branch_changes_requested resubmitted_for_review finalized paid deleted reopened adjustment_added adjustment_approved adjustment_rejected adjustment_removed adjustment_edited line_item_waived overtime_overridden deduction_waived deduction_restored addition_cancelled entry_review_cleared overtime_recalculated recalculated review_slot_completed central_review_reopened].freeze

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
    deduction_restored:        "deduction_restored",
    addition_cancelled:        "addition_cancelled",
    # "Mark Changes Reviewed" — clears the lightweight needs_review flag.
    # Purely an acknowledgement, never a workflow transition.
    entry_review_cleared:      "entry_review_cleared",
    # "إعادة احتساب الوقت الإضافي" — overtime-only recalculation of an
    # under-review period with the current threshold (Payroll::OvertimeRecalculator).
    overtime_recalculated:     "overtime_recalculated",
    # "Recalculate Payroll" — every entry of an under-review / branch-review-
    # completed period recalculated from current data (Payroll::PeriodRecalculator).
    recalculated:              "recalculated",
    # One review slot completed — a branch's or the central one (floating
    # employees); written for every slot, also while other slots stay open.
    review_slot_completed:     "review_slot_completed",
    # The central review was opened after submission (floating employees
    # appeared) or reopened because its reviewed content changed
    # (Payroll::CentralReview#sync!).
    central_review_reopened:   "central_review_reopened"
  }

  validates :action_type, inclusion: { in: ACTION_TYPES }

  def metadata_hash
    return {} if metadata.blank?
    JSON.parse(metadata)
  rescue JSON::ParserError
    {}
  end
end
