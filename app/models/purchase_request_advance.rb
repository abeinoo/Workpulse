# An advance on a Purchase Request. This record is the advance's LIFECYCLE
# only (money never lives here):
#
#   (recorded) ──▶ confirmed ──reverse──▶ reversed
#
# Recording posts the funding at once, in the same transaction
# (Inventory::PurchaseRequestAdvanceRecorder): a new advance is born
# "confirmed" (confirmed_by / confirmed_at = the recorder) — there is no
# second-person confirmation. "pending" survives only on advances recorded
# under the old two-step workflow; they are never executed or replayed, only
#   pending ──cancel──▶ cancelled
# (Inventory::PurchaseRequestAdvanceWorkflow#cancel!), then re-recorded.
#
# FUNDING (every advance recorded since 2026-11-13 — #funding?): the advance
# funds the request's RESPONSIBLE EMPLOYEE's custody (#recipient_custody_account)
# for purchasing. It is NOT a supplier payment: no FinancialSettlement, nothing
# in advances_total, never applied to a Goods Receipt (#unapplied_amount is 0);
# the supplier is paid through the normal Goods Receipt payment, from that
# custody. Recording posts, in the existing custody ledger, by source_kind:
#   - employee_custody: a linked "transfer" pair — the source employee's
#     custody (#custody_account) −amount, the responsible employee's +amount;
#   - company_cash / bank_account: one "purchase_advance_funding" credit on the
#     responsible employee's custody (the company paid it out; there is no
#     company cash/bank ledger to debit — BUG-049).
# #funding_transaction is the credit row (a transfer's counterparty is the
# source debit); reversal posts the opposite rows (#funding_reversal_transaction
# is the responsible-side debit). Originals are never modified.
#
# LEGACY (recorded before that change; recipient_custody_account_id NULL): a
# supplier payment — confirmation posted one FinancialSettlement on the request
# (#financial_settlement, plus an "inventory_purchase" custody debit when paid
# from custody). Its receipt-side consumption and reversal stay unchanged:
# Inventory::PurchaseRequestAdvanceAllocator applies unapplied legacy advances
# oldest-first at Goods Receipt approval, as FinancialSettlement rows whose
# funding_source is the advance (#applied_amount — derived, never stored). A
# legacy advance still PENDING can only be cancelled and re-recorded as
# funding — never converted silently.
class PurchaseRequestAdvance < ApplicationRecord
  # Where the money came from — the same vocabulary as every other payment
  # (FinancialSettlement::PAYMENT_SOURCE_KINDS).
  SOURCE_KINDS = FinancialSettlement::PAYMENT_SOURCE_KINDS

  enum :status, { pending: "pending", confirmed: "confirmed", cancelled: "cancelled", reversed: "reversed" }

  belongs_to :business
  belongs_to :purchase_request
  belongs_to :custody_account, optional: true
  belongs_to :financial_settlement, optional: true
  belongs_to :recipient_custody_account, class_name: "CustodyAccount", optional: true
  belongs_to :funding_transaction,          class_name: "CustodyTransaction", optional: true
  belongs_to :funding_reversal_transaction, class_name: "CustodyTransaction", optional: true
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
  validate  :recipient_differs_from_source
  validate  :same_business

  scope :chronological, -> { order(:confirmed_at, :id) }

  def employee_custody? = source_kind == "employee_custody"

  # Derived from data shape: an advance that names the custody it funds.
  def funding? = recipient_custody_account_id.present?
  def legacy? = !funding?
  def custody_transfer? = funding? && employee_custody?

  # Amount of this advance already consumed by receipts: net SUM over its
  # receipt-side settlements (a voided receipt's reversal rows cancel out).
  def applied_amount
    applications.sum(:amount)
  end

  # Funding never paid the supplier, so there is nothing to apply.
  def unapplied_amount
    return 0 unless confirmed?
    return 0 if funding?

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

  def recipient_differs_from_source
    return if recipient_custody_account_id.nil? || recipient_custody_account_id != custody_account_id

    errors.add(:recipient_custody_account, :same_as_source)
  end

  def same_business
    errors.add(:purchase_request, :invalid) if purchase_request && purchase_request.business_id != business_id
    errors.add(:custody_account, :invalid) if custody_account && custody_account.business_id != business_id
    if recipient_custody_account && recipient_custody_account.business_id != business_id
      errors.add(:recipient_custody_account, :invalid)
    end
  end
end
