class TillHandover < ApplicationRecord
  include AuditLoggable

  belongs_to :daily_reconciliation, inverse_of: :till_handovers
  belongs_to :from_user,    class_name: "User"
  belongs_to :to_user,      class_name: "User", optional: true
  belongs_to :cancelled_by, class_name: "User", optional: true
  belongs_to :rejected_by,  class_name: "User", optional: true
  belongs_to :reversed_by,  class_name: "User", optional: true

  # Self-referential reversal link.
  # reversal_of: the original handover this record reverses.
  # reversal:    the compensating handover created when this one was reversed.
  belongs_to :reversal_of_handover,
             class_name: "TillHandover",
             optional:   true

  has_one :reversal_handover,
          class_name:  "TillHandover",
          foreign_key: :reversal_of_handover_id,
          inverse_of:  :reversal_of_handover,
          dependent:   :restrict_with_error

  # Self-referential correction link.
  # corrects_handover: the original opening float handover this record corrects.
  # correction_handover: the correcting handover created when this one was superseded.
  belongs_to :corrects_handover,
             class_name: "TillHandover",
             optional:   true

  has_one :correction_handover,
          class_name:  "TillHandover",
          foreign_key: :corrects_handover_id,
          inverse_of:  :corrects_handover,
          dependent:   :restrict_with_error

  belongs_to :superseded_by, class_name: "User", optional: true

  has_many :amounts, class_name: "TillHandoverAmount", dependent: :destroy

  has_many :financial_adjustments, as: :adjustable, dependent: :restrict_with_error

  # DR seeded by this handover's next_day_amounts (set by NextDayDrPreparer).
  has_one :seeded_daily_reconciliation,
          class_name:  "DailyReconciliation",
          foreign_key: :opening_float_source_handover_id,
          inverse_of:  :opening_float_source_handover

  validates :to_user, presence: true, unless: :self_deposit?

  # peer: real cashier-to-cashier transfers. Excludes self_deposit (close-day)
  # records, which exist only to carry employee amounts and seed next-day floats.
  # Use this scope in every query that counts, lists, or acts on handovers as
  # business transfers. The only places that legitimately include self-deposit
  # records are: EmployeeReconciliationSummarizer, build_timeline_events, and
  # opening-float navigation via opening_float_source_handover.
  scope :peer,      -> { where(self_deposit: false) }

  # pending: awaiting acceptance by a named recipient.
  # Excludes self-deposit (close events), cancelled, and rejected records —
  # none of those is "awaiting" anything in the business sense.
  scope :pending,   -> { peer.where(accepted_at: nil, cancelled_at: nil, rejected_at: nil) }
  scope :accepted,  -> { where.not(accepted_at: nil) }
  scope :cancelled, -> { where.not(cancelled_at: nil) }
  scope :rejected,  -> { where.not(rejected_at: nil) }
  scope :reversed,  -> { where.not(reversed_at: nil) }
  scope :reversals, -> { where.not(reversal_of_handover_id: nil) }

  delegate :business, :branch, to: :daily_reconciliation

  def pending?     = !self_deposit? && accepted_at.nil? && cancelled_at.nil? && rejected_at.nil?
  def accepted?    = accepted_at.present?
  def cancelled?   = cancelled_at.present?
  def rejected?    = rejected_at.present?
  def reversed?    = reversed_at.present?
  def superseded?  = superseded_at.present?

  # True when this record IS the compensating reversal event (not the original).
  def reversal?    = reversal_of_handover_id.present?

  # True when this record IS a correction of a superseded opening float handover.
  def correction?  = corrects_handover_id.present?

  # Operational amounts for this handover, read through any FinancialAdjustment
  # recorded against it. The original TillHandoverAmount rows are never mutated
  # by an adjustment (Finance::TillHandoverAdjuster is explicitly documentary) —
  # this is the single place every downstream consumer (EmployeeReconciliationSummarizer,
  # minimum-amount validation/hints, sync_session_amounts!) should read from, so a
  # saved adjustment takes effect everywhere immediately without touching history.
  #
  # Later adjustments win per payment method; a payment method not covered by any
  # adjustment falls back to its original recorded amount.
  #
  # Returns an array of { payment_method_id:, payment_method_name:, payment_method:,
  # collected_amount:, refund_amount: }.
  def effective_operational_amounts
    # Chaining .operational/.includes (or, below, .order) onto `amounts`/
    # `financial_adjustments` always issues a fresh query — even when the
    # association was already eager-loaded (e.g. a caller iterating many
    # handovers, such as EmployeeReconciliationSummarizer, preloading
    # amounts: :payment_method and :financial_adjustments up front). Reuse
    # the loaded array in that case instead of re-querying per handover.
    operational_amounts = if amounts.loaded?
      amounts.select { |ha| ha.kind == "operational" }
    else
      amounts.operational.includes(:payment_method).to_a
    end

    base = operational_amounts.map do |ha|
      {
        payment_method_id:   ha.payment_method_id,
        payment_method_name: ha.payment_method_name,
        payment_method:      ha.payment_method,
        collected_amount:    ha.collected_amount,
        refund_amount:       ha.refund_amount
      }
    end

    overrides = {}
    ordered_adjustments = financial_adjustments.loaded? ?
      financial_adjustments.sort_by(&:created_at) :
      financial_adjustments.order(:created_at)
    ordered_adjustments.each do |adjustment|
      Array(adjustment.after_data).each do |entry|
        pm_id = (entry["payment_method_id"] || entry[:payment_method_id]).to_i
        overrides[pm_id] = entry
      end
    end
    return base if overrides.empty?

    base.map do |row|
      override = overrides[row[:payment_method_id]]
      next row unless override

      collected = (override["collected_amount"] || override[:collected_amount]).to_s
      refund    = (override["refund_amount"]    || override[:refund_amount]).to_s

      row.merge(
        collected_amount: collected.presence&.to_d || row[:collected_amount],
        refund_amount:    refund.presence&.to_d    || row[:refund_amount]
      )
    end
  end
end
