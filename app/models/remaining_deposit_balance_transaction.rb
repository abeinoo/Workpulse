class RemainingDepositBalanceTransaction < ApplicationRecord
  # dispute_reserved  — an open ATM Deposit Dispute has claimed part of this
  #                     balance: the employee already declared what happened
  #                     to that cash, so it's reserved out of "still owed"
  #                     while the Bank Dispute workflow investigates it.
  # dispute_released  — the reserving dispute resolved (refunded/rejected/
  #                     confirmed_successful) without yet becoming a real
  #                     deposit, so the reserved amount is restored to
  #                     "still owed". Always paired with an earlier
  #                     dispute_reserved on the same bank_dispute_id.
  TYPES = %w[created settlement reassignment write_off adjustment dispute_reserved dispute_released].freeze

  enum :transaction_type, {
    created:          "created",
    settlement:       "settlement",
    reassignment:     "reassignment",
    write_off:        "write_off",
    adjustment:       "adjustment",
    dispute_reserved: "dispute_reserved",
    dispute_released: "dispute_released"
  }

  belongs_to :remaining_deposit_balance, inverse_of: :balance_transactions
  belongs_to :performed_by,              class_name: "User"
  belongs_to :previous_responsible_user, class_name: "User", optional: true
  belongs_to :new_responsible_user,      class_name: "User", optional: true
  belongs_to :payment_method,            optional: true
  belongs_to :bank_dispute,              optional: true
  # A "settlement" made by crediting an employee's Custody Account (a Shortage
  # Settlement Deposit, Finance::BulkShortageCustodySettler) names that exact
  # custody row — no payment method, no cash/card/bank movement.
  belongs_to :custody_transaction,       optional: true

  validates :transaction_type, inclusion: { in: TYPES }
  validates :amount, numericality: { greater_than: 0 }, allow_nil: true
  validates :amount, presence: true,
            if: -> { created? || settlement? || write_off? || adjustment? || dispute_reserved? || dispute_released? }
  validates :bank_dispute_id, presence: true, if: -> { dispute_reserved? || dispute_released? }
  # Backstop for every writer: a ledger row never names another business's
  # payment method (BUG-032). Rows are append-only, so this runs on create.
  validate  :payment_method_in_balance_business, on: :create
  validate  :custody_transaction_matches_balance, on: :create

  # Append-only — no record may ever be mutated or destroyed.
  def readonly? = !new_record?
  before_destroy { throw :abort }

  def payment_method_in_balance_business
    return if payment_method.nil? || remaining_deposit_balance.nil?

    errors.add(:payment_method_id, :other_business) if payment_method.business_id != remaining_deposit_balance.business_id
  end

  # Settled into a custody account rather than through a payment method.
  def custody_settlement? = settlement? && custody_transaction_id.present?

  # The custody link is only ever a settlement's, mirrors it exactly (same
  # amount, positive Shortage Settlement Deposit sourced from THIS balance),
  # and never carries a payment method alongside it.
  def custody_transaction_matches_balance
    return if custody_transaction.nil?

    ct = custody_transaction
    valid = settlement? && payment_method_id.nil? &&
            ct.shortage_settlement_deposit? && ct.voided_at.nil? &&
            ct.source_type == "RemainingDepositBalance" &&
            ct.source_id == remaining_deposit_balance_id &&
            amount.present? && ct.amount == amount
    errors.add(:custody_transaction_id, :invalid) unless valid
  end

  scope :ordered,     -> { order(:created_at) }
  scope :settlements, -> { where(transaction_type: "settlement") }
  scope :write_offs,  -> { where(transaction_type: "write_off") }
end
