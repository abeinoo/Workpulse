class TillDeposit < ApplicationRecord
  include Voidable
  include AuditLoggable

  belongs_to :daily_reconciliation, inverse_of: :till_deposits
  belongs_to :payment_method
  belongs_to :deposited_by, class_name: "User"

  validates :amount,       presence: true, numericality: { greater_than: 0 }
  validates :deposited_at, presence: true

  validate :payment_method_must_be_cash_like

  private

  def payment_method_must_be_cash_like
    return unless payment_method
    return if payment_method.cash_like?

    errors.add(:payment_method, :not_cash_like)
  end
end
