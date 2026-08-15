class SalesTransaction < ApplicationRecord
  # "amount" always stores a positive magnitude — a refund is identified by
  # transaction_type, not by sign. #signed_amount is the derived value used
  # wherever refunds must net out of a sales total (negative for a refund).
  TRANSACTION_TYPES = %w[sale refund].freeze

  belongs_to :sales_import
  belongs_to :business
  belongs_to :daily_reconciliation, optional: true

  validates :transaction_date,    presence: true
  validates :cashier_name,        presence: true
  validates :branch_name,         presence: true
  validates :payment_method_name, presence: true
  validates :amount,              numericality: { greater_than: 0 }
  validates :reference_number,    uniqueness: { scope: :business_id }, allow_nil: true
  validates :transaction_type,    inclusion: { in: TRANSACTION_TYPES }

  scope :ordered,     -> { order(:transaction_date, :cashier_name, :payment_method_name) }
  scope :matched,     -> { where.not(daily_reconciliation_id: nil) }
  scope :unmatched,   -> { where(daily_reconciliation_id: nil) }
  scope :for_cashier, ->(name) { where(cashier_name: name) }
  scope :sales,       -> { where(transaction_type: "sale") }
  scope :refunds,     -> { where(transaction_type: "refund") }

  def refund? = transaction_type == "refund"
  def sale?   = !refund?

  # Sales add, refunds subtract — the single signed figure every reconciliation
  # sum should use so gross/refund/net stay consistent without a second
  # calculation path.
  def signed_amount
    refund? ? -amount : amount
  end
end
