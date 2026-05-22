class PayrollLineItem < ApplicationRecord
  belongs_to :payroll_entry
  belongs_to :reviewed_by, class_name: "User", optional: true

  ITEM_TYPES = %w[
    late_penalty early_leave_penalty overtime advance_deduction obligation_deduction
    cash_incentive commission
    penalty manual_deduction manual_adjustment
  ].freeze
  # System-generated attendance items are auto-approved.
  # Manager-submitted positive types start as pending_review (unless already_paid, which auto-approves).
  # already_paid items skip review — the money is already out the door.
  REVIEW_REQUIRED_TYPES = %w[commission cash_incentive penalty manual_deduction].freeze

  enum :item_type, {
    late_penalty:         "late_penalty",
    early_leave_penalty:  "early_leave_penalty",
    overtime:             "overtime",
    advance_deduction:    "advance_deduction",
    obligation_deduction: "obligation_deduction",
    cash_incentive:       "cash_incentive",
    commission:           "commission",
    penalty:              "penalty",
    manual_adjustment:    "manual_adjustment",
    manual_deduction:     "manual_deduction"
  }

  attribute :review_status, :string, default: "approved"
  attribute :reviewed_at,   :datetime
  attribute :review_notes,  :text

  enum :review_status, {
    pending_review: "pending_review",
    approved:       "approved",
    rejected:       "rejected",
    waived:         "waived"
  }

  validates :item_type, :amount, :review_status, presence: true

  def addition?
    amount.to_f >= 0
  end

  def deduction?
    amount.to_f < 0
  end

  def reviewable?
    REVIEW_REQUIRED_TYPES.include?(item_type)
  end
end
