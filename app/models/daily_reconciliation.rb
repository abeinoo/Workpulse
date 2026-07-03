class DailyReconciliation < ApplicationRecord
  include AuditLoggable

  STATES = %w[open waiting_for_opening closed deposited verified].freeze
  enum :state, {
    open:                "open",
    waiting_for_opening: "waiting_for_opening",
    closed:              "closed",
    deposited:           "deposited",
    verified:            "verified"
  }

  # ── Aggregate root associations ──────────────────────────────────────────────
  belongs_to :branch
  belongs_to :business
  belongs_to :verified_by, class_name: "User", optional: true

  # Set when a previous-day self-deposit handover carried next_day_amounts.
  # Cleared (set to nil) once the opening float has been received.
  belongs_to :opening_float_source_handover, class_name: "TillHandover", optional: true

  # TillSession is an internal operational child — never accessed independently.
  # Always created together with this record via create_for!.
  has_one :till_session,  foreign_key: :daily_reconciliation_id,
                          inverse_of:  :daily_reconciliation,
                          dependent:   :destroy

  has_many :till_handovers, foreign_key: :daily_reconciliation_id,
                            inverse_of:  :daily_reconciliation,
                            dependent:   :destroy

  has_many :till_deposits, foreign_key: :daily_reconciliation_id,
                           inverse_of:  :daily_reconciliation,
                           dependent:   :restrict_with_error

  # Official per-payment-method totals snapshot — written at day close.
  # Accounting data; owned by DR, not TillSession.
  has_many :session_amounts, class_name: "TillSessionAmount", dependent: :destroy

  has_many :deposit_responsibility_transfers, dependent: :destroy
  has_many :employee_reconciliation_summaries, dependent: :destroy
  has_many :remaining_deposit_balances, dependent: :destroy, inverse_of: :daily_reconciliation
  has_many :remaining_deposit_balance_transactions,
           through: :remaining_deposit_balances,
           source:  :balance_transactions

  has_many :pos_transactions, dependent: :destroy

  # ── Validations ──────────────────────────────────────────────────────────────
  validates :state,     inclusion: { in: STATES }
  validates :opened_at, presence: true
  validates :verified_at, presence: true, if: -> { verified_by.present? }

  # ── Scopes ───────────────────────────────────────────────────────────────────
  scope :for_business, ->(business) { where(business: business) }
  scope :for_branch,   ->(branch)   { where(branch: branch) }
  scope :ordered,      ->           { order(opened_at: :desc) }
  scope :verified,     ->           { where.not(verified_at: nil) }
  scope :unverified,   ->           { where(verified_at: nil) }

  def verified?   = verified_at.present?
  def unverified? = !verified?

  def active_deposits = till_deposits.active
  def total_deposited = till_deposits.active.sum(:amount)

  # Sum of cash-like session amounts — the target the depositor is responsible for.
  def expected_cash_deposit
    session_amounts.joins(:payment_method)
                   .where(payment_methods: { settlement_type: "cash" })
                   .sum("collected_amount - refund_amount")
  end

  # How much is still outstanding before this deposit form is submitted.
  def pending_deposit_amount
    (expected_cash_deposit - total_deposited).clamp(0, Float::INFINITY)
  end

  # Sum of currently outstanding cash across all open remaining balances.
  def total_remaining_balance
    remaining_deposit_balances.open.sum(:remaining_amount)
  end

  # Cash that was outstanding at close but settled later via the ledger.
  def total_settled_later
    remaining_deposit_balance_transactions
      .joins(:remaining_deposit_balance)
      .where(remaining_deposit_balances: { status: "settled" },
             remaining_deposit_balance_transactions: { transaction_type: "settlement" })
      .sum("remaining_deposit_balance_transactions.amount")
  end

  # Cash written off by management decision.
  def total_written_off
    remaining_deposit_balance_transactions
      .where(transaction_type: "write_off")
      .sum("remaining_deposit_balance_transactions.amount")
  end

  # Returns the current open reconciliation for a branch, or nil.
  # Never creates — use create_for! to open a new accounting day.
  def self.open_for(branch)
    open.find_by(branch: branch)
  end

  # Returns a waiting_for_opening reconciliation for a branch, or nil.
  def self.waiting_for(branch)
    waiting_for_opening.find_by(branch: branch)
  end

  # True when the DR is blocked pending opening float receipt.
  def blocked_by_opening_float?
    waiting_for_opening?
  end

  # True when the float may actually be received.
  # Receivable as soon as the current Business Day has advanced past the float's
  # date — i.e. business_date is today OR any earlier date still in waiting state
  # (stale record that was never received).  The business day rolls over at
  # business.business_day_start_hour, never at midnight.
  def opening_float_receivable?
    waiting_for_opening? &&
      business_date <= BusinessDay.current(context: business)
  end

  # Creates a new DailyReconciliation and its child TillSession atomically.
  # This is the only place a TillSession may be created.
  # If either record fails, the entire transaction rolls back.
  #
  # business_date is stamped at creation using BusinessDay so the DR carries
  # the correct accounting date even if it is closed after the day rolls over.
  #
  # current_holder is intentionally NOT pre-set.  Custody is established the
  # moment the first handover is accepted; until then no one "holds" the till,
  # and the closing validation ("block only if someone else holds it") correctly
  # allows the acting cashier to proceed.
  def self.create_for!(branch:, created_by: nil) # created_by kept for call-site compatibility
    transaction do
      reconciliation = create!(
        branch:        branch,
        business:      branch.business,
        state:         "open",
        opened_at:     Time.current,
        business_date: BusinessDay.current(context: branch.business)
      )

      reconciliation.create_till_session!

      reconciliation
    end
  end

  # Creates a next-day DR in waiting_for_opening state with a child TillSession
  # (no holder yet). Called only by Finance::NextDayDrPreparer — never directly.
  def self.prepare_for_next_day!(branch:, business_date:, source_handover:)
    transaction do
      reconciliation = create!(
        branch:                       branch,
        business:                     branch.business,
        state:                        "waiting_for_opening",
        opened_at:                    Time.current,
        business_date:                business_date,
        opening_float_source_handover: source_handover
      )

      reconciliation.create_till_session!

      reconciliation
    end
  end
end
