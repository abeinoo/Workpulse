# One payment event against any "settleable" document — the append-only
# ledger that Settleable#financial_status is derived from (SUM(amount) vs.
# the settleable's #settlement_total). Never updated after creation; a
# correction (e.g. reversing a voided document's settlement) is always a new,
# separate row with an equal-and-opposite amount.
#
# This is the generic financial settlement engine: any document that needs to
# be paid off from a funding source (GoodsReceipt today; PurchaseInvoice,
# Expense, Payroll, SalaryAdvance, VendorPayment, BranchTransfer, ... later)
# includes the Settleable concern and is created/reversed through
# FinancialSettlementService — never built by hand.
class FinancialSettlement < ApplicationRecord
  # Document types allowed to be settled. Extend as new modules adopt the
  # engine (PurchaseInvoice, Expense, SalaryAdvance, Payroll, VendorPayment,
  # BranchTransfer, ...).
  SETTLEABLE_TYPES = %w[GoodsReceipt Expense PurchaseRequest].freeze

  # Funding sources allowed to settle a document. Only CustodyAccount is
  # functional today; the rest are added as they're implemented (CompanyCash,
  # BankAccount, SupplierCredit).
  #
  # funding_source may also be NIL: money paid through a means this system
  # doesn't model as a trackable account (company cash, a bank transfer,
  # someone else entirely). The payment itself is still real — a normal
  # immutable ledger row that Total Paid / Remaining include exactly like any
  # other — it simply moves no internal balance and has nothing to link to.
  #
  # PurchaseRequestAdvance funds the receipt-side "application" rows: a
  # Goods Receipt paid (partly) out of an advance already paid against its
  # Purchase Request (see Inventory::PurchaseRequestAdvanceAllocator). No money
  # moves on those rows — it moved once, when the advance was confirmed.
  FUNDING_SOURCE_TYPES = %w[CustodyAccount PurchaseRequestAdvance].freeze

  # WHERE the money came from — reuses the existing funding-source vocabulary
  # (GoodsReceipt::FUNDING_SOURCE_KINDS), minus supplier_credit, which is the
  # absence of a payment, not a way of paying. Only employee_custody is backed
  # by a trackable account (funding_source = CustodyAccount); company_cash and
  # bank_account settlements carry a NIL funding_source because no CashAccount /
  # BankAccount model exists yet — they record a real payment but move no
  # internal balance. When such a model is added, it joins FUNDING_SOURCE_TYPES
  # and #funding_source_matches_kind is relaxed for its kind.
  # NIL source_kind = legacy untracked expense payment (cash vs. bank unknown).
  #
  # PAYMENT_SOURCE_KINDS are real ways of paying (offered on payment forms);
  # ADVANCE_APPLICATION_KIND is internal only — the receipt-side consumption of
  # a Purchase Request advance — and is never accepted from a payment form.
  PAYMENT_SOURCE_KINDS = (GoodsReceipt::FUNDING_SOURCE_KINDS - %w[supplier_credit]).freeze
  ADVANCE_APPLICATION_KIND = "purchase_request_advance".freeze
  SOURCE_KINDS = (PAYMENT_SOURCE_KINDS + [ ADVANCE_APPLICATION_KIND ]).freeze
  ACCOUNTLESS_SOURCE_KINDS = %w[company_cash bank_account].freeze

  belongs_to :settleable, polymorphic: true
  belongs_to :funding_source, polymorphic: true, optional: true
  belongs_to :created_by, class_name: "User", optional: true

  # A reversal is a separate row pointing at the exact original it undoes
  # (unique index: each settlement can be reversed at most once).
  belongs_to :reverses_settlement, class_name: "FinancialSettlement", optional: true, inverse_of: :reversal
  has_one    :reversal, class_name: "FinancialSettlement", foreign_key: :reverses_settlement_id,
                        inverse_of: :reverses_settlement, dependent: :restrict_with_error
  # The custody movement this settlement produced (custody-funded rows only).
  has_one    :custody_transaction, inverse_of: :financial_settlement, dependent: :restrict_with_error

  validates :amount, presence: true, numericality: { other_than: 0 }
  validates :settled_at, presence: true
  validates :settleable_type, inclusion: { in: SETTLEABLE_TYPES }
  validates :funding_source_type, inclusion: { in: FUNDING_SOURCE_TYPES }, allow_nil: true
  validates :source_kind, inclusion: { in: SOURCE_KINDS }, allow_nil: true
  validate  :funding_source_in_same_business
  validate  :funding_source_matches_kind
  validate  :advance_funding_only_for_applications
  validate  :reversal_mirrors_original, on: :create

  before_validation :default_source_kind_from_funding_source, on: :create

  scope :chronological, -> { order(:settled_at, :id) }
  scope :originals,     -> { where(reverses_settlement_id: nil) }
  # Originals that are still in effect — the only rows a void/reversal may undo.
  scope :unreversed,    -> { originals.where.missing(:reversal) }
  scope :advance_applications, -> { where(source_kind: ADVANCE_APPLICATION_KIND) }

  def reversal? = reverses_settlement_id.present?
  def advance_application? = source_kind == ADVANCE_APPLICATION_KIND
  def reversed? = reversal.present?

  before_update  { raise ActiveRecord::ReadOnlyRecord, "FinancialSettlement records are immutable after creation." }
  before_destroy { raise ActiveRecord::ReadOnlyRecord, "FinancialSettlement records cannot be deleted." }

  private

  def funding_source_in_same_business
    return if settleable.nil? || funding_source.nil?
    return unless funding_source.respond_to?(:business_id) && settleable.respond_to?(:business_id)

    errors.add(:funding_source, :invalid) if funding_source.business_id != settleable.business_id
  end

  # Existing callers (goods receipt approval, expense approval/payments) only
  # pass a CustodyAccount — tag those rows without having to change them.
  def default_source_kind_from_funding_source
    self.source_kind ||= "employee_custody" if funding_source.is_a?(CustodyAccount)
  end

  # Any other source kind must not carry an advance as its funding source.
  def advance_funding_only_for_applications
    errors.add(:funding_source, :invalid) if funding_source.is_a?(PurchaseRequestAdvance) && !advance_application?
  end

  def funding_source_matches_kind
    if source_kind == "employee_custody"
      errors.add(:funding_source, :required) unless funding_source.is_a?(CustodyAccount)
    elsif advance_application?
      errors.add(:funding_source, :required) unless funding_source.is_a?(PurchaseRequestAdvance)
    elsif ACCOUNTLESS_SOURCE_KINDS.include?(source_kind) && funding_source.present?
      errors.add(:funding_source, :must_be_blank)
    end
  end

  def reversal_mirrors_original
    return if reverses_settlement.nil?

    original = reverses_settlement
    errors.add(:reverses_settlement, :invalid) if original.reversal?
    errors.add(:reverses_settlement, :invalid) unless original.settleable_type == settleable_type &&
                                                      original.settleable_id == settleable_id
    errors.add(:amount, :invalid) unless amount.present? && amount == -original.amount
  end
end
