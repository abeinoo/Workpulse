class TillHandover < ApplicationRecord
  include AuditLoggable

  belongs_to :daily_reconciliation, inverse_of: :till_handovers
  belongs_to :from_user,    class_name: "User"
  belongs_to :to_user,      class_name: "User", optional: true
  belongs_to :cancelled_by, class_name: "User", optional: true
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
  # Excludes self-deposit (close events) and cancelled records — neither of
  # those is "awaiting" anything in the business sense.
  scope :pending,   -> { peer.where(accepted_at: nil, cancelled_at: nil) }
  scope :accepted,  -> { where.not(accepted_at: nil) }
  scope :cancelled, -> { where.not(cancelled_at: nil) }
  scope :reversed,  -> { where.not(reversed_at: nil) }
  scope :reversals, -> { where.not(reversal_of_handover_id: nil) }

  delegate :business, :branch, to: :daily_reconciliation

  def pending?   = !self_deposit? && accepted_at.nil? && cancelled_at.nil?
  def accepted?  = accepted_at.present?
  def cancelled? = cancelled_at.present?
  def reversed?  = reversed_at.present?

  # True when this record IS the compensating reversal event (not the original).
  def reversal?  = reversal_of_handover_id.present?
end
