class DailyReconciliation < ApplicationRecord
  include AuditLoggable

  belongs_to :business
  belongs_to :branch
  belongs_to :verified_by, class_name: "User", optional: true

  validates :business_date, presence: true
  validates :verified_at,   presence: true, if: -> { verified_by.present? }

  scope :for_business, ->(business) { where(business: business) }
  scope :verified,     -> { where.not(verified_at: nil) }
  scope :unverified,   -> { where(verified_at: nil) }
  scope :ordered,      -> { order(business_date: :desc) }

  def verified?   = verified_at.present?
  def unverified? = !verified?

  # ── Computed financials (all derived at query time) ───────────────────────

  # All accepted handovers for this branch / date, ordered by chain position.
  def handover_chain
    TillHandover
      .for_branch_date(branch, business_date)
      .accepted
      .includes(:lines, :from_user, :to_user)
      .order(:created_at)
  end

  # Net collected per payment method across the entire chain.
  def collected_by_method
    TillHandoverLine
      .joins(:till_handover)
      .where(till_handovers: { branch_id: branch_id, business_date: business_date })
      .joins(:payment_method)
      .group("payment_methods.id", "payment_methods.name")
      .sum("till_handover_lines.collected_amount - till_handover_lines.refund_amount")
  end

  # Total cash deposited (active deposits only).
  def total_deposited
    TillDeposit
      .joins(:till_handover)
      .where(
        till_handovers: { branch_id: branch_id, business_date: business_date },
        voided_at: nil
      )
      .sum(:amount)
  end
end
