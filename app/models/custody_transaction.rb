class CustodyTransaction < ApplicationRecord
  include Voidable
  include Attachable

  belongs_to :business
  belongs_to :custody_account
  belongs_to :expense,               optional: true
  belongs_to :transfer_counterparty, class_name: "CustodyTransaction", optional: true
  belongs_to :created_by,  class_name: "User", optional: true
  belongs_to :approved_by, class_name: "User", optional: true
  belongs_to :source, polymorphic: true, optional: true

  # Whitelist for the polymorphic #source link (mirrors FinancialAdjustment#adjustable) —
  # currently only used to trace an inventory_purchase/inventory_purchase_reversal
  # back to the GoodsReceipt that caused it.
  SOURCE_TYPES = %w[GoodsReceipt].freeze

  has_one_attached :document
  validates_attachment :document,
    content_types: Attachable::DOCUMENT_CONTENT_TYPES,
    max_size:      Attachable::DEFAULT_DOCUMENT_SIZE

  # Amount stored SIGNED — balance = SUM(amount) over non-voided rows.
  # Positive: top_up, upward adjustment / transfer in.
  # Negative: expense_deduction, downward adjustment / transfer out.
  TXN_TYPES = %w[top_up expense_deduction transfer adjustment inventory_purchase
                 inventory_purchase_reversal expense_deduction_reversal].freeze
  enum :txn_type, { top_up: "top_up", expense_deduction: "expense_deduction",
                    transfer: "transfer", adjustment: "adjustment",
                    inventory_purchase: "inventory_purchase",
                    inventory_purchase_reversal: "inventory_purchase_reversal",
                    expense_deduction_reversal: "expense_deduction_reversal" }

  validates :amount, presence: true, numericality: true
  validates :source_type, inclusion: { in: SOURCE_TYPES }, allow_nil: true
  validate  :amount_sign_matches_type
  validate  :account_in_same_business
  validate  :expense_in_same_business

  scope :for_business, ->(business)    { where(business: business) }
  scope :for_account,  ->(account_id)  { where(custody_account_id: account_id) if account_id.present? }
  scope :of_type,      ->(type)        { where(txn_type: type) if type.present? }
  scope :recent,       -> { order(created_at: :desc, id: :desc) }

  private

  def amount_sign_matches_type
    return if amount.blank?

    case txn_type
    when "top_up"
      errors.add(:amount, :must_be_positive) unless amount.positive?
    when "expense_deduction", "inventory_purchase"
      errors.add(:amount, :must_be_negative) unless amount.negative?
    when "inventory_purchase_reversal", "expense_deduction_reversal"
      errors.add(:amount, :must_be_positive) unless amount.positive?
    when "transfer", "adjustment"
      errors.add(:amount, :must_not_be_zero) if amount.zero?
    end
  end

  def account_in_same_business
    return if custody_account.nil? || business_id.nil?

    errors.add(:custody_account, :invalid) if custody_account.business_id != business_id
  end

  def expense_in_same_business
    return if expense.nil? || business_id.nil?

    errors.add(:expense, :invalid) if expense.business_id != business_id
  end
end
