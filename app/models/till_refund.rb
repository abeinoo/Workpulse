class TillRefund < ApplicationRecord
  include AuditLoggable

  belongs_to :daily_reconciliation, inverse_of: :till_refunds
  belongs_to :payment_method
  belongs_to :processed_by, class_name: "User"

  validates :amount,       presence: true, numericality: { greater_than: 0 }
  validates :refunded_at,  presence: true

  delegate :business, :branch, to: :daily_reconciliation
end
