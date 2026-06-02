class PayrollAdjustment < ApplicationRecord
  belongs_to :business
  belongs_to :payroll_period, optional: true
  belongs_to :user
  belongs_to :created_by,  class_name: "User"
  belongs_to :reviewed_by, class_name: "User", optional: true
  belongs_to :approved_by, class_name: "User", optional: true
  belongs_to :rejected_by, class_name: "User", optional: true

  # Positive adjustments add to salary; negative adjustments deduct.
  # already_paid: positive adjustments that were already handed to the employee in cash.
  # They appear in payroll reporting/history but do NOT increase net payable salary.
  POSITIVE_TYPES   = %w[cash_incentive commission].freeze
  NEGATIVE_TYPES   = %w[penalty manual_deduction].freeze
  ADJUSTMENT_TYPES = (POSITIVE_TYPES + NEGATIVE_TYPES).freeze
  PAYMENT_METHODS  = %w[cash bank_transfer check other].freeze
  REVIEW_STATUSES  = %w[pending_review approved rejected].freeze

  enum :adjustment_type, {
    cash_incentive:   "cash_incentive",
    commission:       "commission",
    penalty:          "penalty",
    manual_deduction: "manual_deduction",
    # Legacy DB values — readable but blocked on write by the ADJUSTMENT_TYPES inclusion validation below
    bonus:            "bonus",
    reward:           "reward",
    eid_bonus:        "eid_bonus"
  }, validate: false

  enum :review_status, {
    pending_review: "pending_review",
    approved:       "approved",
    rejected:       "rejected"
  }

  validates :adjustment_type, inclusion: { in: ADJUSTMENT_TYPES }
  validates :amount, numericality: { greater_than: 0 }
  validates :reason, presence: true
  validates :business,      presence: true
  validates :period_month,  presence: true, inclusion: { in: 1..12 }
  validates :period_year,   presence: true, numericality: { greater_than: 2000 }
  validates :payment_method, inclusion: { in: PAYMENT_METHODS }, allow_nil: true
  validate  :already_paid_only_for_positive, if: -> { already_paid? }
  validate  :period_not_locked, on: :create
  validate  :user_belongs_to_business
  validate  :creator_is_not_approver

  scope :for_period,    ->(year, month) { where(period_year: year, period_month: month) }
  # Period-range filtering for the index. Compares a (year, month) pair as a single
  # ordinal (year * 12 + month) so ranges spanning a year boundary work correctly.
  scope :period_on_or_after,  ->(date) { date.present? ? where("payroll_adjustments.period_year * 12 + payroll_adjustments.period_month >= ?", date.year * 12 + date.month) : all }
  scope :period_on_or_before, ->(date) { date.present? ? where("payroll_adjustments.period_year * 12 + payroll_adjustments.period_month <= ?", date.year * 12 + date.month) : all }
  scope :for_business,  ->(biz)         { where(business: biz) }
  scope :pending,       ->              { where(review_status: "pending_review") }
  scope :approved,      ->              { where(review_status: "approved") }
  scope :already_paid,  ->              { where(already_paid: true) }
  scope :by_type,       ->(type)        { where(adjustment_type: type) if type.present? }
  scope :by_status,     ->(status)      { where(review_status: status) if status.present? }
  scope :for_user,      ->(uid)         { where(user_id: uid) if uid.present? }
  scope :for_branch,    ->(branch_id)   { joins(user: :user_branches).where(user_branches: { branch_id: branch_id }) if branch_id.present? }
  scope :search_reason, ->(q)           { where("reason ILIKE ?", "%#{q}%") if q.present? }
  scope :for_batch,     ->(batch_id)    { where(bulk_batch_id: batch_id) if batch_id.present? }

  IMPORT_SOURCES = %w[manual csv_import].freeze

  def signed_amount
    positive? ? amount : -amount
  end

  # ── Approval transitions ──────────────────────────────────────────────────
  # The ONLY place an adjustment changes review_status. Callers must have already
  # checked Payroll::AdjustmentApproval.permitted? (policy or service layer); the
  # creator_is_not_approver validation is the final backstop on write.
  def approve_by!(reviewer)
    update!(
      review_status: "approved",
      approved_by:   reviewer,
      approved_at:   Time.current,
      reviewed_by:   reviewer,
      reviewed_at:   Time.current
    )
  end

  def reject_by!(reviewer, notes: nil)
    update!(
      review_status: "rejected",
      rejected_by:   reviewer,
      rejected_at:   Time.current,
      reviewed_by:   reviewer,
      reviewed_at:   Time.current,
      review_notes:  notes
    )
  end

  # Legacy DB values that predate the type consolidation.
  LEGACY_TYPE_MAP = {
    "bonus"     => "cash_incentive",
    "reward"    => "cash_incentive",
    "eid_bonus" => "cash_incentive"
  }.freeze

  def positive?
    POSITIVE_TYPES.include?(line_item_type)
  end

  # Maps to the matching PayrollLineItem item_type, normalising legacy DB values.
  def line_item_type
    LEGACY_TYPE_MAP.fetch(adjustment_type.to_s, adjustment_type.to_s)
  end

  private

  def already_paid_only_for_positive
    errors.add(:already_paid, "is only valid for cash incentive adjustments") unless cash_incentive?
  end

  def user_belongs_to_business
    return unless user && business
    errors.add(:user, "does not belong to this business") if user.business_id != business_id
  end

  def period_not_locked
    # Review-time adjustments (linked to a specific payroll_period) are always allowed —
    # they are created intentionally during the review workflow.
    return if payroll_period_id.present?
    return unless business_id && period_month && period_year

    period = PayrollPeriod.find_by(
      business_id:  business_id,
      period_month: period_month,
      period_year:  period_year
    )
    return unless period

    if period.finalized? || period.paid?
      # Payroll has been processed/closed — no further adjustments are permitted.
      errors.add(:base, I18n.t("adjustments.errors.period_processed"))
    elsif period.under_review? || period.branch_review_completed?
      errors.add(:base, I18n.t("adjustments.errors.period_under_review"))
    end
  end

  # Enforces creator != approver at the data layer. Even if a controller or service
  # tried to approve an adjustment with the same user that created it, the record
  # is rejected. approved_by is only ever set when an approval actually occurs.
  def creator_is_not_approver
    return if approved_by_id.blank?
    return if created_by_id.blank?

    if approved_by_id == created_by_id
      errors.add(:approved_by, I18n.t("adjustments.errors.creator_is_approver"))
    end
  end
end
