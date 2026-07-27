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

  validates :transaction_type, inclusion: { in: TYPES }
  validates :amount, numericality: { greater_than: 0 }, allow_nil: true
  validates :amount, presence: true,
            if: -> { created? || settlement? || write_off? || adjustment? || dispute_reserved? || dispute_released? }
  validates :bank_dispute_id, presence: true, if: -> { dispute_reserved? || dispute_released? }

  # Append-only — no record may ever be mutated or destroyed.
  def readonly? = !new_record?
  before_destroy { throw :abort }

  scope :ordered,     -> { order(:created_at) }
  scope :settlements, -> { where(transaction_type: "settlement") }
  scope :write_offs,  -> { where(transaction_type: "write_off") }
end
