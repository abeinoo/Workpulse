class BankStatementTransaction < ApplicationRecord
  include AuditLoggable

  belongs_to :bank_statement
  belongs_to :business
  belongs_to :matched_till_deposit, class_name: "TillDeposit", optional: true
  belongs_to :matched_by,           class_name: "User",        optional: true

  STATUSES = %w[pending verified amount_mismatch date_mismatch unexpected ignored needs_reverification].freeze
  MATCH_METHODS = %w[auto_reference auto_amount_date manual].freeze

  validates :transaction_date, presence: true
  validates :amount,           presence: true,
                               numericality: { greater_than: 0 }
  validates :status,           inclusion: { in: STATUSES }
  validates :match_method,     inclusion: { in: MATCH_METHODS }, allow_nil: true

  scope :for_business, ->(b) { where(business: b) }
  scope :pending,      -> { where(status: "pending") }
  scope :verified,     -> { where(status: "verified") }
  scope :unexpected,   -> { where(status: "unexpected") }
  scope :mismatched,   -> { where(status: %w[amount_mismatch date_mismatch]) }
  scope :ignored,      -> { where(status: "ignored") }
  scope :matched,      -> { where.not(matched_till_deposit_id: nil) }
  scope :unmatched,    -> { where(matched_till_deposit_id: nil) }
  scope :ordered,      -> { order(transaction_date: :desc, created_at: :desc) }

  def verified?              = status == "verified"
  def unexpected?            = status == "unexpected"
  def amount_mismatch?       = status == "amount_mismatch"
  def date_mismatch?         = status == "date_mismatch"
  def ignored?               = status == "ignored"
  def needs_reverification?  = status == "needs_reverification"
  def matched?               = matched_till_deposit_id.present?
  def manual_match?          = match_method == "manual"
  def has_snapshot?          = snapshot_deposit_amount.present?

  def amount_difference
    return nil unless matched_till_deposit
    (amount - matched_till_deposit.amount).abs
  end
end
