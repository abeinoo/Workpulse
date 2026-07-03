class TillDeposit < ApplicationRecord
  include Voidable
  include AuditLoggable

  belongs_to :daily_reconciliation, inverse_of: :till_deposits
  belongs_to :payment_method
  belongs_to :deposited_by, class_name: "User"

  has_one :bank_statement_transaction, foreign_key: :matched_till_deposit_id, dependent: :nullify

  validates :amount,       presence: true, numericality: { greater_than: 0 }
  validates :deposited_at, presence: true

  validate :payment_method_must_be_cash_like

  VERIFICATION_CRITICAL_FIELDS = %w[amount deposited_at reference payment_method_id voided_at].freeze

  after_save :invalidate_bank_verification_if_critical_change

  private

  def invalidate_bank_verification_if_critical_change
    return unless bank_statement_transaction.present?
    return if bank_statement_transaction.ignored?
    return unless VERIFICATION_CRITICAL_FIELDS.any? { |f| saved_change_to_attribute?(f) }

    previous_status = bank_statement_transaction.status
    bank_statement_transaction.update_columns(status: "needs_reverification")

    log_audit(
      actor:     deposited_by,
      auditable: bank_statement_transaction,
      action:    :verification_invalidated,
      changes:   VERIFICATION_CRITICAL_FIELDS.filter_map { |f|
                   change = saved_change_to_attribute(f)
                   [ f, change ] if change
                 }.to_h,
      metadata:  { previous_status: previous_status }
    )
  end

  def payment_method_must_be_cash_like
    return unless payment_method
    return if payment_method.cash_like?

    errors.add(:payment_method, :not_cash_like)
  end
end
