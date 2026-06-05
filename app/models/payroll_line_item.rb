class PayrollLineItem < ApplicationRecord
  belongs_to :payroll_entry
  belongs_to :reviewed_by, class_name: "User", optional: true
  belongs_to :deduction_waived_by, class_name: "User", optional: true

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

  # True when this line item was materialised from a PayrollAdjustment (manager-
  # submitted bonus/commission/penalty/deduction) rather than system-generated
  # from attendance. Only these carry a human creator for the approval rule.
  def adjustment_sourced?
    source_type == "PayrollAdjustment"
  end

  def source_adjustment
    return @source_adjustment if defined?(@source_adjustment)

    @source_adjustment = adjustment_sourced? ? PayrollAdjustment.find_by(id: source_id) : nil
  end

  # The user who created the underlying adjustment, or nil for system-generated
  # items. Feeds the creator != approver clause of Payroll::AdjustmentApproval.
  def source_creator
    source_adjustment&.created_by
  end

  # ── Manual deduction waiver layer ───────────────────────────────────────────
  # A payroll-level layer (distinct from the review_status workflow) that lets a
  # payroll user excuse a manual deduction without touching the source adjustment.
  # Only manual deductions are waivable. `deduction_waived` is the boolean column.
  scope :manual_deductions,        -> { where(item_type: "manual_deduction") }
  scope :waived_deductions,        -> { manual_deductions.where(deduction_waived: true) }
  scope :active_manual_deductions, -> { manual_deductions.where(deduction_waived: false) }

  # Only manual deductions participate in the waiver layer.
  def deduction_waivable?
    manual_deduction?
  end

  # Human-facing waiver state for display: "waived" or "active".
  def waiver_status
    deduction_waived? ? "waived" : "active"
  end
end
