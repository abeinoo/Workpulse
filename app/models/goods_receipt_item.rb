class GoodsReceiptItem < ApplicationRecord
  belongs_to :goods_receipt
  belongs_to :product
  # Optional: which Purchase Request line this receipt line fulfils. Set only
  # when the receipt was created from a Purchase Request (see
  # GoodsReceiptsController#new). The hard, race-safe "don't over-receive"
  # guard lives in Inventory::GoodsReceiptPoster (the actual posting
  # transaction) — this model only carries the reference.
  belongs_to :purchase_request_item, optional: true

  has_one :business, through: :goods_receipt

  validates :quantity,  numericality: { greater_than: 0 }
  validates :unit_cost, numericality: { greater_than_or_equal_to: 0 }
  validate  :product_is_transactable
  validate  :product_matches_purchase_request_item
  validate  :purchase_request_item_required_when_receipt_linked
  # Soft, non-locking check for early feedback while a draft is being
  # created/edited — not a substitute for GoodsReceiptPoster's locked check,
  # which is the only place that's actually race-safe.
  validate  :within_remaining_quantity

  def product_is_transactable
    return unless product
    errors.add(:product_id, :parent_not_allowed) if Product.where(parent_product_id: product.id).exists?
  end

  before_validation :compute_total_cost

  private

  def compute_total_cost
    self.total_cost = quantity.to_d * unit_cost.to_d if quantity && unit_cost
  end

  def product_matches_purchase_request_item
    return if purchase_request_item.nil? || product.nil?

    errors.add(:product_id, :invalid) if purchase_request_item.product_id != product_id
  end

  # Closes off the over-receiving guard's one gap: it only ever checks a line
  # that carries a purchase_request_item reference. Without this, a line on a
  # PR-linked receipt with that reference stripped (e.g. a tampered form
  # submission) would post with no remaining-quantity check at all. Once a
  # receipt is linked to a Purchase Request, every one of its lines must
  # point at one of that request's own items — no unconstrained lines.
  def purchase_request_item_required_when_receipt_linked
    return unless goods_receipt&.purchase_request_id.present?

    if purchase_request_item.nil?
      errors.add(:purchase_request_item, :required)
    elsif purchase_request_item.purchase_request_id != goods_receipt.purchase_request_id
      errors.add(:purchase_request_item, :invalid)
    end
  end

  def within_remaining_quantity
    return if purchase_request_item.nil? || quantity.nil?

    remaining = purchase_request_item.remaining_quantity
    # A previously-persisted line being re-saved unchanged already counts
    # toward "received" via other confirmed receipts, never itself (this
    # receipt isn't confirmed yet — see PurchaseRequestItem#received_quantity),
    # so no self-exclusion is needed here.
    return if quantity <= remaining

    errors.add(:quantity, :exceeds_remaining_quantity, remaining: remaining)
  end
end
