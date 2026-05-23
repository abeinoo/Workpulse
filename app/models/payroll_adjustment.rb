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

  scope :for_period,    ->(year, month) { where(period_year: year, period_month: month) }
  scope :for_business,  ->(biz)         { where(business: biz) }
  scope :pending,       ->              { where(review_status: "pending_review") }
  scope :approved,      ->              { where(review_status: "approved") }
  scope :already_paid,  ->              { where(already_paid: true) }

  def signed_amount
    positive? ? amount : -amount
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

  def period_not_locked
    # Review-time adjustments (linked to a specific payroll_period) are always allowed —
    # they are created intentionally during the review workflow.
    return if payroll_period_id.present?
    return unless business_id && period_month && period_year

    locked = PayrollPeriod.where(
      business_id:  business_id,
      period_month: period_month,
      period_year:  period_year,
      status:       %w[under_review branch_review_completed finalized paid]
    ).exists?

    errors.add(:base, "Adjustments cannot be created after payroll has been submitted for review") if locked
  end
end
