class BankStatementTransaction < ApplicationRecord
  include AuditLoggable

  belongs_to :bank_statement
  belongs_to :business

  has_many :deposit_matches, dependent: :destroy
  has_many :till_deposits, through: :deposit_matches

  STATUSES = %w[
    pending verified amount_mismatch date_mismatch unexpected ignored
    needs_reverification needs_manual_review
  ].freeze
  MATCH_METHODS = %w[
    auto_reference auto_amount_date auto_amount_near_date auto_amount_only
    auto_description_similarity manual
  ].freeze

  validates :transaction_date, presence: true
  validates :amount,           presence: true,
                               numericality: { greater_than: 0 }
  validates :status,           inclusion: { in: STATUSES }
  validates :match_method,     inclusion: { in: MATCH_METHODS }, allow_nil: true
  validates :match_confidence, numericality: { only_integer: true, in: 0..100 }, allow_nil: true

  scope :for_business, ->(b) { where(business: b) }
  scope :pending,      -> { where(status: "pending") }
  scope :verified,     -> { where(status: "verified") }
  scope :unexpected,   -> { where(status: "unexpected") }
  scope :mismatched,   -> { where(status: %w[amount_mismatch date_mismatch]) }
  scope :ignored,      -> { where(status: "ignored") }
  scope :matched,      -> { where.associated(:deposit_matches) }
  scope :unmatched,    -> { where.missing(:deposit_matches) }
  scope :ordered,      -> { order(transaction_date: :desc, created_at: :desc) }

  def verified?              = status == "verified"
  def unexpected?            = status == "unexpected"
  def amount_mismatch?       = status == "amount_mismatch"
  def date_mismatch?         = status == "date_mismatch"
  def ignored?               = status == "ignored"
  def needs_reverification?  = status == "needs_reverification"
  def needs_manual_review?   = status == "needs_manual_review"
  def matched?               = deposit_matches.exists?
  def manual_match?          = match_method == "manual"

  # Verified, on a statement that still exists — the only state in which this
  # transaction's deposit link counts as confirmed bank evidence.
  def confirms_deposit?      = verified? && !bank_statement.deleted?

  # A deposit link held by this transaction that someone must act on: the
  # bank verification was invalidated, or its statement has been deleted.
  def link_needs_attention?  = needs_reverification? || bank_statement.deleted?

  # A transaction backs at most one deposit today (see DepositMatch's
  # uniqueness constraint) — these delegate to that single pairing for the
  # many call sites that only care about "the" match. Once partial
  # allocation is built (multiple deposits per transaction), these become
  # ambiguous and callers should switch to #deposit_matches/#till_deposits.
  def matched_till_deposit = till_deposits.first
  def matched_at           = deposit_matches.first&.matched_at
  def matched_by           = deposit_matches.first&.matched_by

  def amount_difference
    return nil unless matched_till_deposit
    (amount - matched_till_deposit.amount).abs
  end

  # A date_mismatch transaction is, by the matching rule, never linked to a
  # deposit — so there's no association to read a day-gap from. This finds
  # the nearest same-amount, still-unmatched deposit and reports how many
  # days apart it is, purely for display (e.g. "3 days apart") so the
  # accountant can judge whether a Manual Match override is warranted.
  def date_mismatch_days
    return nil unless date_mismatch?

    candidate = TillDeposit.joins(:daily_reconciliation)
                  .where(daily_reconciliations: { business_id: business_id })
                  .where(amount: amount, voided_at: nil)
                  .where.missing(:deposit_matches)
                  .to_a
                  .min_by { |d| (d.deposited_at.to_date - transaction_date).to_i.abs }
    return nil unless candidate

    (candidate.deposited_at.to_date - transaction_date).to_i.abs
  end
end
