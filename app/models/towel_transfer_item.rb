# One towel type + quantity line on a TowelTransfer document. Mirrors
# StockIssueItem/GoodsReceiptItem's header + line-items shape — towel_status
# stays on the header (TowelTransfer) since it's derived from branch types,
# identical for every line on the same document.
class TowelTransferItem < ApplicationRecord
  belongs_to :towel_transfer
  belongs_to :towel_type

  has_one :business, through: :towel_transfer

  validates :declared_quantity, numericality: { greater_than: 0 }
  validates :confirmed_quantity, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
  # DB-backed uniqueness only catches conflicts against already-persisted rows
  # — it can't see a sibling built in the same unsaved accepts_nested_attributes_for
  # collection, so #towel_type_unique_within_transfer below is what actually
  # rejects two new lines with the same towel type submitted together.
  validates :towel_type_id, uniqueness: { scope: :towel_transfer_id }
  validate  :towel_type_in_same_business
  validate  :towel_type_unique_within_transfer
  # Scoped to when either field actually changes — mirrors
  # TowelTransfer's original guard so historical bad rows stay editable for
  # unrelated updates without re-triggering this validation.
  validate  :confirmed_quantity_not_more_than_declared,
            if: -> { confirmed_quantity_changed? || declared_quantity_changed? }

  # Always >= 0 — confirmed_quantity can never exceed declared_quantity (see
  # confirmed_quantity_not_more_than_declared), so a negative discrepancy
  # (receiving more than was dispatched) is impossible by construction.
  def discrepancy
    return nil unless confirmed_quantity
    declared_quantity - confirmed_quantity
  end

  private

  def towel_type_in_same_business
    return if towel_type.nil? || towel_transfer.nil? || towel_transfer.business_id.nil?
    errors.add(:towel_type, :invalid) if towel_type.business_id != towel_transfer.business_id
  end

  def towel_type_unique_within_transfer
    return if towel_type_id.nil? || towel_transfer.nil?

    siblings = towel_transfer.items.reject { |item| item.marked_for_destruction? || item.equal?(self) }
    errors.add(:towel_type_id, :taken) if siblings.any? { |item| item.towel_type_id == towel_type_id }
  end

  # Receiving more than was dispatched would create untracked stock with no
  # valid source — reject it outright rather than let it become a negative
  # discrepancy. This is defense in depth; Laundry::TowelTransferCreator#receive
  # checks this first and never posts a ledger entry when it fails.
  def confirmed_quantity_not_more_than_declared
    return if confirmed_quantity.nil?
    errors.add(:confirmed_quantity, :exceeds_declared, declared: declared_quantity) if confirmed_quantity > declared_quantity
  end
end
