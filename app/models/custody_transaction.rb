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
  # The exact FinancialSettlement row this movement settles (a payment's debit)
  # or undoes (a reversal's credit) — alongside #source, which still points at
  # the settled document. Unique: at most one custody movement per settlement.
  belongs_to :financial_settlement, optional: true, inverse_of: :custody_transaction

  # Whitelist for the polymorphic #source link (mirrors FinancialAdjustment#adjustable) —
  # used to trace an inventory_purchase/inventory_purchase_reversal back to the
  # GoodsReceipt that caused it, or to the PurchaseRequest whose advance
  # payment caused it (see PurchaseRequestAdvance), or a shortage_settlement_deposit
  # back to the RemainingDepositBalance (cash shortage) it settled.
  SOURCE_TYPES = %w[GoodsReceipt PurchaseRequest RemainingDepositBalance].freeze

  has_one_attached :document
  validates_attachment :document,
    content_types: Attachable::DOCUMENT_CONTENT_TYPES,
    max_size:      Attachable::DEFAULT_DOCUMENT_SIZE

  # Amount stored SIGNED — balance = SUM(amount) over non-voided rows.
  # Positive: top_up, upward adjustment / transfer in, purchase_advance_funding.
  # Negative: expense_deduction, downward adjustment / transfer out,
  # purchase_advance_funding_reversal.
  # purchase_advance_funding is company cash / bank money given to a Purchase
  # Request's responsible employee through a confirmed advance — kept apart
  # from a manual top_up so the two stay distinguishable.
  # shortage_settlement_deposit is a Remaining Deposit Balance (cash shortage)
  # settled by making the selected employee accountable for that cash in
  # custody (Finance::BulkShortageCustodySettler) — positive, source = the
  # RemainingDepositBalance, at most one active per balance (DB partial unique
  # index). No cash drawer, deposit or payment method is involved.
  TXN_TYPES = %w[top_up expense_deduction transfer adjustment inventory_purchase
                 inventory_purchase_reversal expense_deduction_reversal
                 purchase_advance_funding purchase_advance_funding_reversal
                 shortage_settlement_deposit].freeze
  enum :txn_type, { top_up: "top_up", expense_deduction: "expense_deduction",
                    transfer: "transfer", adjustment: "adjustment",
                    inventory_purchase: "inventory_purchase",
                    inventory_purchase_reversal: "inventory_purchase_reversal",
                    expense_deduction_reversal: "expense_deduction_reversal",
                    purchase_advance_funding: "purchase_advance_funding",
                    purchase_advance_funding_reversal: "purchase_advance_funding_reversal",
                    shortage_settlement_deposit: "shortage_settlement_deposit" }

  validates :amount, presence: true, numericality: true
  validates :source_type, inclusion: { in: SOURCE_TYPES }, allow_nil: true
  validate  :amount_sign_matches_type
  validate  :account_in_same_business
  validate  :expense_in_same_business
  validate  :mirrors_financial_settlement, on: :create
  validate  :settlement_linked_not_voided_directly, on: :update
  validate  :advance_funding_not_voided_directly, on: :update
  validate  :shortage_settlement_source_valid, on: :create
  validate  :shortage_settlement_not_voided_directly, on: :update

  scope :for_business, ->(business)    { where(business: business) }
  scope :for_account,  ->(account_id)  { where(custody_account_id: account_id) if account_id.present? }
  scope :of_type,      ->(type)        { where(txn_type: type) if type.present? }
  scope :recent,       -> { order(created_at: :desc, id: :desc) }

  # The custody side of a FinancialSettlement (a payment's debit or a
  # reversal's credit). Its lifecycle belongs to the settlement: it is undone
  # only by reversing the settlement, which posts a new, linked credit — never
  # by voiding this row, which would move the balance while the settlement
  # still counts as paid.
  def settlement_linked? = financial_settlement_id.present?

  # A row a Purchase Request advance's FUNDING posted (a transfer leg or a
  # company funding credit, or their reversals): its #source is the request and
  # it settles nothing (a legacy advance's rows are settlement_linked?). Undone
  # only by reversing that advance, which posts the opposite rows — voiding one
  # would leave the advance confirmed with no money moved.
  def advance_funding? = source_type == "PurchaseRequest" && !settlement_linked?

  # A Shortage Settlement Deposit closed a RemainingDepositBalance whose
  # append-only ledger now names this row. Voiding it would put the cash back
  # out of custody while the shortage stays "settled" — so it can never be
  # voided on its own (Finance::TransactionVoider refuses; the model enforces it).
  def shortage_settlement? = shortage_settlement_deposit?

  private

  # A Shortage Settlement Deposit always names the balance it settled, from
  # the same business.
  def shortage_settlement_source_valid
    return unless shortage_settlement_deposit?

    unless source.is_a?(RemainingDepositBalance) && source.business_id == business_id
      errors.add(:source, :invalid)
    end
  end

  # Model-level backstop for #shortage_settlement?, like the ones below.
  def shortage_settlement_not_voided_directly
    return unless shortage_settlement? && will_save_change_to_voided_at? && voided_at.present?

    errors.add(:base, :shortage_settlement_void)
  end

  # Model-level backstop for #settlement_linked?: blocks voiding through ANY
  # path (service, console, future code), not just Finance::TransactionVoider.
  def settlement_linked_not_voided_directly
    return unless settlement_linked? && will_save_change_to_voided_at? && voided_at.present?

    errors.add(:base, :settlement_linked_void)
  end

  # Model-level backstop for #advance_funding?, like the one above.
  def advance_funding_not_voided_directly
    return unless advance_funding? && will_save_change_to_voided_at? && voided_at.present?

    errors.add(:base, :advance_funding_void)
  end

  # A settlement-linked movement must be the exact custody side of that
  # settlement: same account, equal-and-opposite amount (settlement +2,000 ↔
  # custody −2,000; reversal −2,000 ↔ custody +2,000).
  def mirrors_financial_settlement
    return if financial_settlement.nil?

    errors.add(:financial_settlement, :invalid) unless financial_settlement.funding_source_type == "CustodyAccount" &&
                                                       financial_settlement.funding_source_id == custody_account_id
    errors.add(:amount, :invalid) unless amount.present? && amount == -financial_settlement.amount
  end

  def amount_sign_matches_type
    return if amount.blank?

    case txn_type
    when "top_up", "purchase_advance_funding", "shortage_settlement_deposit"
      errors.add(:amount, :must_be_positive) unless amount.positive?
    when "purchase_advance_funding_reversal"
      errors.add(:amount, :must_be_negative) unless amount.negative?
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
