class GoodsReceiptItem < ApplicationRecord
  include PackagedLine

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
  validate  :product_in_same_business, if: :will_save_change_to_product_id?
  validate  :product_matches_purchase_request_item
  validate  :purchase_request_item_consistent_with_receipt
  # Soft, non-locking check for early feedback while a draft is being
  # created/edited — not a substitute for GoodsReceiptPoster's locked check,
  # which is the only place that's actually race-safe.
  validate  :within_remaining_quantity

  # Line product ids come straight from form params — never trust one that
  # belongs to another business (IP-1).
  def product_in_same_business
    return if product.nil? || goods_receipt.nil? || goods_receipt.business_id.nil?

    errors.add(:product_id, :other_business) if product.business_id != goods_receipt.business_id
  end

  # A price entered per the chosen unit (e.g. 120.00 a carton) is stored per
  # base unit at 8 dp (unit_cost); the line total keeps the entered figures.
  before_validation :derive_base_unit_cost
  before_validation :compute_total_cost

  private

  def derive_base_unit_cost
    return if entered_unit_cost.blank?

    factor = packaging_level ? packaging_level.base_quantity.to_d : 1.to_d
    self.unit_cost = (entered_unit_cost.to_d / factor).round(8)
  end

  def compute_total_cost
    if entered_unit_cost.present? && entered_quantity.present?
      self.total_cost = (entered_quantity.to_d * entered_unit_cost.to_d).round(4)
    elsif quantity && unit_cost
      self.total_cost = quantity.to_d * unit_cost.to_d
    end
  end

  public

  # The price per the unit the user entered (base lines: the base price).
  def unit_cost_per_entered_unit
    entered_unit_cost.presence || unit_cost
  end

  private

  def product_matches_purchase_request_item
    return if purchase_request_item.nil? || product.nil?

    errors.add(:product_id, :invalid) if purchase_request_item.product_id != product_id
  end

  # A receipt linked to a Purchase Request records what was actually bought:
  # the request's lines (each pointing at its purchase_request_item) plus any
  # extra catalog products bought beyond the request (no reference). Extras
  # never touch the request — its received/remaining quantities count only
  # referenced lines (PurchaseRequestItem#received_quantity).
  #
  # The over-receiving guard only checks referenced lines, so a product that IS
  # on the request must go through its request line: an unreferenced line for
  # it (e.g. a reference stripped from a tampered form) would otherwise post
  # with no remaining-quantity check. A reference must belong to this request.
  #
  # A request line with a supplier may only be received from that supplier: a
  # receipt has one supplier, so a request buying from several is received in
  # one receipt per supplier. The lines without a supplier are received in
  # their own receipt (never mixed with a supplier's lines —
  # GoodsReceipt#purchase_request_lines_one_supplier_group).
  def purchase_request_item_consistent_with_receipt
    return unless goods_receipt&.purchase_request_id.present?

    if purchase_request_item.nil?
      on_request = product_id &&
                   PurchaseRequestItem.where(purchase_request_id: goods_receipt.purchase_request_id, product_id: product_id).exists?
      errors.add(:product_id, :on_purchase_request) if on_request
    elsif purchase_request_item.purchase_request_id != goods_receipt.purchase_request_id
      errors.add(:purchase_request_item, :invalid)
    elsif purchase_request_item.supplier_id.present? && purchase_request_item.supplier_id != goods_receipt.supplier_id
      errors.add(:purchase_request_item, :supplier_mismatch)
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
