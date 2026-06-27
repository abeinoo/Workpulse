class DailyReconciliation < ApplicationRecord
  include AuditLoggable

  STATES = %w[open closed deposited verified].freeze
  enum :state, { open: "open", closed: "closed", deposited: "deposited", verified: "verified" }

  # ── Aggregate root associations ──────────────────────────────────────────────
  belongs_to :branch
  belongs_to :business
  belongs_to :verified_by, class_name: "User", optional: true

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

  # Creates a new DailyReconciliation and its child TillSession atomically.
  # This is the only place a TillSession may be created.
  # If either record fails, the entire transaction rolls back.
  def self.create_for!(branch:, created_by:)
    transaction do
      reconciliation = create!(
        branch:    branch,
        business:  branch.business,
        state:     "open",
        opened_at: Time.current
      )

      reconciliation.create_till_session!(current_holder: created_by)

      reconciliation
    end
  end
end
