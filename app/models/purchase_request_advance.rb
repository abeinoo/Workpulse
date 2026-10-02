# An advance payment / deposit paid to a Purchase Request's supplier before
# the goods arrive. This record is the advance's LIFECYCLE only:
#
#   pending ──confirm──▶ confirmed ──reverse──▶ reversed
#      └────cancel────▶ cancelled
#
# Money never lives here. Confirmation (Inventory::PurchaseRequestAdvanceWorkflow)
# posts the existing ledgers inside one transaction:
#   - one FinancialSettlement on the Purchase Request (#financial_settlement),
#     funded by the employee's CustodyAccount or accountless (company cash /
#     bank) — the same engine and source kinds as Goods Receipt payments;
#   - for employee custody, the linked "inventory_purchase" CustodyTransaction
#     debit (CustodyTransaction#financial_settlement), never a balance edit.
# Reversal posts the equal-and-opposite settlement (+ custody credit); the
# original rows are never modified.
#
# Receiving consumes it: when a Goods Receipt created from the Purchase
# Request is approved, Inventory::PurchaseRequestAdvanceAllocator applies
# unapplied advances oldest-first as FinancialSettlement rows on the receipt
# whose funding_source is this advance — so "applied" / "unapplied" are always
# derived from that ledger (#applied_amount), never stored.
class PurchaseRequestAdvance < ApplicationRecord
  # Where the money came from — the same vocabulary as every other supplier
  # payment (FinancialSettlement::PAYMENT_SOURCE_KINDS).
  SOURCE_KINDS = FinancialSettlement::PAYMENT_SOURCE_KINDS

  enum :status, { pending: "pending", confirmed: "confirmed", cancelled: "cancelled", reversed: "reversed" }

  belongs_to :business
  belongs_to :purchase_request
  belongs_to :custody_account, optional: true
  belongs_to :financial_settlement, optional: true
  belongs_to :created_by,   class_name: "User", optional: true
  belongs_to :confirmed_by, class_name: "User", optional: true
  belongs_to :cancelled_by, class_name: "User", optional: true
  belongs_to :reversed_by,  class_name: "User", optional: true

  # Receipt-side applications of this advance (and their reversals when a
  # receipt is voided) — see Inventory::PurchaseRequestAdvanceAllocator.
  has_many :applications, class_name: "FinancialSettlement", as: :funding_source, dependent: :restrict_with_error

  validates :amount, numericality: { greater_than: 0 }
  validates :source_kind, inclusion: { in: SOURCE_KINDS }
  validates :paid_on, presence: true
  validates :reference, length: { maximum: 120 }, allow_blank: true
  validate  :custody_account_matches_source
  validate  :same_business

  scope :chronological, -> { order(:confirmed_at, :id) }

  def employee_custody? = source_kind == "employee_custody"

  # Amount of this advance already consumed by receipts: net SUM over its
  # receipt-side settlements (a voided receipt's reversal rows cancel out).
  def applied_amount
    applications.sum(:amount)
  end

  def unapplied_amount
    return 0 unless confirmed?

    [ amount - applied_amount, 0 ].max
  end

  private

  def custody_account_matches_source
    if employee_custody?
      errors.add(:custody_account, :blank) if custody_account.nil?
    elsif custody_account.present?
      errors.add(:custody_account, :must_be_blank)
    end
  end

  def same_business
    errors.add(:purchase_request, :invalid) if purchase_request && purchase_request.business_id != business_id
    errors.add(:custody_account, :invalid) if custody_account && custody_account.business_id != business_id
  end
end
