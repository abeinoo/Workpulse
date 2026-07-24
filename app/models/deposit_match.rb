class DepositMatch < ApplicationRecord
  include AuditLoggable

  belongs_to :till_deposit
  belongs_to :bank_statement_transaction
  belongs_to :matched_by, class_name: "User", optional: true

  validates :matched_amount, presence: true, numericality: { greater_than: 0 }
  validates :matched_at, presence: true

  # A bank transaction's full amount can only ever back one deposit's match
  # until partial allocation is built — see matched_amount comment on the
  # underlying migration/index.
  validates :bank_statement_transaction_id, uniqueness: true

  # Shared row-creation helper for both the manual and automatic matchers —
  # keeps "what a match row looks like" in one place while each caller keeps
  # its own status/audit-logging semantics.
  def self.create_for!(till_deposit:, bank_statement_transaction:, matched_by: nil, matched_at: Time.current)
    create!(
      till_deposit:               till_deposit,
      bank_statement_transaction: bank_statement_transaction,
      matched_amount:             bank_statement_transaction.amount,
      matched_by:                 matched_by,
      matched_at:                 matched_at
    )
  end
end
