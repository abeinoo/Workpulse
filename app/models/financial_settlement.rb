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
  SETTLEABLE_TYPES = %w[GoodsReceipt Expense].freeze

  # Funding sources allowed to settle a document. Only CustodyAccount is
  # functional today; the rest are added as they're implemented (CompanyCash,
  # BankAccount, SupplierCredit).
  #
  # funding_source may also be NIL: money paid through a means this system
  # doesn't model as a trackable account (company cash, a bank transfer,
  # someone else entirely). The payment itself is still real — a normal
  # immutable ledger row that Total Paid / Remaining include exactly like any
  # other — it simply moves no internal balance and has nothing to link to.
  FUNDING_SOURCE_TYPES = %w[CustodyAccount].freeze

  belongs_to :settleable, polymorphic: true
  belongs_to :funding_source, polymorphic: true, optional: true
  belongs_to :created_by, class_name: "User", optional: true

  validates :amount, presence: true, numericality: { other_than: 0 }
  validates :settled_at, presence: true
  validates :settleable_type, inclusion: { in: SETTLEABLE_TYPES }
  validates :funding_source_type, inclusion: { in: FUNDING_SOURCE_TYPES }, allow_nil: true
  validate  :funding_source_in_same_business

  scope :chronological, -> { order(:settled_at, :id) }

  before_update  { raise ActiveRecord::ReadOnlyRecord, "FinancialSettlement records are immutable after creation." }
  before_destroy { raise ActiveRecord::ReadOnlyRecord, "FinancialSettlement records cannot be deleted." }

  private

  def funding_source_in_same_business
    return if settleable.nil? || funding_source.nil?
    return unless funding_source.respond_to?(:business_id) && settleable.respond_to?(:business_id)

    errors.add(:funding_source, :invalid) if funding_source.business_id != settleable.business_id
  end
end
