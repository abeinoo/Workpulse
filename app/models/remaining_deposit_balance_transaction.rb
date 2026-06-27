class RemainingDepositBalanceTransaction < ApplicationRecord
  TYPES = %w[created settlement reassignment write_off adjustment].freeze

  enum :transaction_type, {
    created:      "created",
    settlement:   "settlement",
    reassignment: "reassignment",
    write_off:    "write_off",
    adjustment:   "adjustment"
  }

  belongs_to :remaining_deposit_balance, inverse_of: :balance_transactions
  belongs_to :performed_by,              class_name: "User"
  belongs_to :previous_responsible_user, class_name: "User", optional: true
  belongs_to :new_responsible_user,      class_name: "User", optional: true
  belongs_to :payment_method,            optional: true

  validates :transaction_type, inclusion: { in: TYPES }
  validates :amount, numericality: { greater_than: 0 }, allow_nil: true
  validates :amount, presence: true,
            if: -> { created? || settlement? || write_off? || adjustment? }

  # Append-only — no record may ever be mutated or destroyed.
  def readonly? = !new_record?
  before_destroy { throw :abort }

  scope :ordered,     -> { order(:created_at) }
  scope :settlements, -> { where(transaction_type: "settlement") }
  scope :write_offs,  -> { where(transaction_type: "write_off") }
end
