class PayrollPeriod < ApplicationRecord
  belongs_to :business
  belongs_to :branch,        optional: true   # retained for historical data; new periods always nil
  belongs_to :generated_by,  class_name: "User", optional: true
  belongs_to :finalized_by,  class_name: "User", optional: true
  has_many   :payroll_entries,               dependent: :destroy
  has_many   :payroll_period_branch_reviews, dependent: :destroy
  has_many   :payroll_adjustments,           dependent: :nullify
  has_many   :payroll_audit_logs,            dependent: :nullify
  has_many   :obligation_deductions,         dependent: :destroy
  has_many   :payroll_snapshots,             dependent: :destroy

  STATUSES = %w[draft under_review branch_review_completed finalized paid].freeze

  enum :status, {
    draft:                    "draft",
    under_review:             "under_review",
    branch_review_completed:  "branch_review_completed",
    finalized:                "finalized",
    paid:                     "paid"
  }

  validates :period_year,  presence: true, numericality: { greater_than: 2000 }
  validates :period_month, presence: true, inclusion: { in: 1..12 }
  validates :working_days, presence: true, numericality: { greater_than: 0 }
  validates :period_year, uniqueness: { scope: [:business_id, :period_month],
                                        message: "already has a payroll period for this month" }

  scope :for_business, ->(business) { where(business: business) }

  def period_label
    "#{I18n.t("date.month_names")[period_month]} #{period_year}"
  end

  def period_start
    Date.new(period_year, period_month, 1)
  end

  def period_end
    period_start.end_of_month
  end

  # All branch review slots have been approved (completed). Pending or
  # changes_requested slots both block advancement — only :completed counts.
  def all_branches_reviewed?
    payroll_period_branch_reviews.any? &&
      payroll_period_branch_reviews.where(status: %w[pending changes_requested]).none?
  end

  # True when at least one branch has requested changes and none are still pending.
  # Used to surface the "needs attention" state to accounting.
  def changes_requested?
    payroll_period_branch_reviews.where(status: "changes_requested").any?
  end

  # Unresolved (pending_review) adjustments that pay into this period: review-time
  # adjustments linked to it, plus standalone ones (no payroll_period_id) for its
  # business + month — the same business/month resolution EntryCalculator,
  # AdjustmentApplier and PayrollAdjustment#review_period use (one period per
  # business + month, enforced by a unique index). Counted per adjustment, so an
  # adjustment that is also materialised as a line item is counted once.
  def pending_adjustments
    PayrollAdjustment.pending
                     .where(business_id: business_id)
                     .where("payroll_adjustments.payroll_period_id = :id OR " \
                            "(payroll_adjustments.period_year = :year AND payroll_adjustments.period_month = :month)",
                            id: id, year: period_year, month: period_month)
  end

  # Locking: finalized and paid periods are immutable.
  def locked?
    finalized? || paid?
  end

  def editable?
    !locked?
  end

  # Reason key used for i18n flash messages.
  def lock_reason
    return nil unless locked?
    paid? ? :paid : :finalized
  end
end
