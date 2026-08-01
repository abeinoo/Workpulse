class SalesTransaction < ApplicationRecord
  belongs_to :sales_import
  belongs_to :business
  belongs_to :daily_reconciliation, optional: true

  validates :transaction_date,    presence: true
  validates :cashier_name,        presence: true
  validates :branch_name,         presence: true
  validates :payment_method_name, presence: true
  validates :amount,              numericality: { greater_than: 0 }
  validates :reference_number,    uniqueness: { scope: :business_id }, allow_nil: true

  scope :ordered,     -> { order(:transaction_date, :cashier_name, :payment_method_name) }
  scope :matched,     -> { where.not(daily_reconciliation_id: nil) }
  scope :unmatched,   -> { where(daily_reconciliation_id: nil) }
  scope :for_cashier, ->(name) { where(cashier_name: name) }
end
