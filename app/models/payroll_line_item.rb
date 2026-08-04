class PayrollLineItem < ApplicationRecord
  belongs_to :payroll_entry
  belongs_to :reviewed_by, class_name: "User", optional: true
  belongs_to :deduction_waived_by, class_name: "User", optional: true

  ITEM_TYPES = %w[
    late_penalty early_leave_penalty overtime advance_deduction obligation_deduction
    insurance_deduction
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
    insurance_deduction:  "insurance_deduction",
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

  # ── Deduction waiver layer ──────────────────────────────────────────────────
  # A payroll-level layer (distinct from the review_status workflow) that lets a
  # payroll user excuse a deduction without touching its source record.
  # `deduction_waived` is the boolean column, shared by every waivable type.
  #
  # Which deduction types are actually waivable is an explicit business-rule
  # allowlist, not "every deduction" — insurance/advance/obligation deductions
  # are deliberately excluded until a decision is made to support waiving them.
  # This is the ONLY place that decision is made; the persistence layer
  # (Payroll::DeductionWaiverPersistence) treats every allowlisted type
  # identically and has no type-specific logic of its own.
  WAIVABLE_DEDUCTION_TYPES = %w[
    late_penalty early_leave_penalty manual_adjustment manual_deduction penalty
  ].freeze

  scope :manual_deductions,        -> { where(item_type: "manual_deduction") }
  scope :waived_deductions,        -> { manual_deductions.where(deduction_waived: true) }
  scope :active_manual_deductions, -> { manual_deductions.where(deduction_waived: false) }

  # Whether a line item has any monetary effect right now — the single
  # predicate every payroll total (per-entry or period-wide) is built on.
  # Mirrors PayrollEntry#recalculate_totals!'s `active` selection exactly
  # (approved, and not waived — deduction_waived is only ever true for a
  # waivable deduction type, so this is a no-op filter for every other type).
  # A pending_review or rejected item exists for display only and never
  # contributes to a total. Used by Payroll::PeriodFinancialSummary for
  # period-wide SQL aggregation without duplicating this rule.
  scope :financially_active, -> { where(review_status: "approved", deduction_waived: false) }

  def deduction_waivable?
    deduction? && WAIVABLE_DEDUCTION_TYPES.include?(item_type)
  end

  # Human-facing waiver state for display: "waived" or "active".
  def waiver_status
    deduction_waived? ? "waived" : "active"
  end

  # Stable identity for matching a waived line item across a rebuild that
  # destroys and recreates it (and its id) from scratch. Prefers the source
  # record's id, which is stable for every waivable type except the absence
  # deduction (manual_adjustment), which has no source record at all — there
  # is at most one per entry, so the item_type alone is a safe key there.
  def waiver_identity
    source_id.present? ? [ item_type, source_id ] : [ item_type ]
  end
end
