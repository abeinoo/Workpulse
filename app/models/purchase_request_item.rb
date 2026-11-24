class PurchaseRequestItem < ApplicationRecord
  include RequiresActiveWarehouse
  belongs_to :purchase_request
  belongs_to :product
  # LEGACY: the per-line destination warehouse of requests created before the
  # warehouse moved to the request (PurchaseRequest#warehouse). Never written
  # for new lines; kept for those historical requests.
  belongs_to :source_warehouse, class_name: "Warehouse", optional: true
  # Who this line is bought from — optional (unknown or decided later).
  # Pre-filled from product.default_supplier in the form, but it belongs to the
  # line: changing it never touches the product. A Goods Receipt may receive
  # this line only with this same supplier (GoodsReceiptItem).
  belongs_to :supplier, optional: true

  has_one :business, through: :purchase_request
  # The GoodsReceiptItem rows fulfilling this line, across possibly several
  # receipts (partial receiving) — see #received_quantity. Never destroyed
  # here; a posted GoodsReceiptItem is immutable (see ImmutableDocument on
  # GoodsReceipt).
  has_many :goods_receipt_items, dependent: :restrict_with_error

  validates :quantity,   numericality: { greater_than: 0 }
  # Purchase price must be a real, resolved cost — never silently defaulted to
  # 0 (see Inventory::PurchaseRequestCreator, which rejects unpriced items
  # before any record is created).
  validates :unit_price, numericality: { greater_than: 0 }
  validate  :product_in_same_business
  validate  :source_warehouse_in_same_business, if: :will_save_change_to_source_warehouse_id?
  requires_active_warehouse :source_warehouse
  validate  :supplier_in_same_business, if: :will_save_change_to_supplier_id?
  validate  :supplier_matches_legacy_request_supplier, if: :will_save_change_to_supplier_id?

  before_validation :compute_total_cost

  # ── Quantities claimed by Goods Receipts — one definition ─────────────────
  # received   — CONFIRMED, non-voided receipts (a draft receipt hasn't received
  #              anything yet; see GoodsReceipt#status / Voidable#active);
  # approvable — what a receipt being APPROVED (= paid) may still take: ordered
  #              minus every OTHER non-voided receipt that is received or
  #              approved-not-yet-confirmed (already paid, still to arrive).
  # Derived, never cached, so they can never drift from what actually happened.
  # The class methods answer for many lines in ONE grouped query;
  # #received_quantity / #remaining_quantity are the single-line form of the
  # same calculation (approval reads approvable quantities only in bulk).

  # { line id => received quantity } for `lines`, in one query.
  def self.received_quantities(lines)
    claimed_quantities(lines, GoodsReceipt.confirmed)
  end

  # { line id => remaining quantity } (ordered − received, never below 0).
  def self.remaining_quantities(lines)
    received = received_quantities(lines)
    lines.to_h { |line| [ line.id, quantity_left(line.quantity, received[line.id]) ] }
  end

  # { line id => approvable quantity } for the receipt `except_receipt_id`
  # being approved. ONE query, so a receipt confirmed meanwhile (approved →
  # confirmed, without the Purchase Request lock) is counted exactly once. Read
  # under the Purchase Request lock by Inventory::GoodsReceiptApproval#approve!;
  # confirmation stays the final guard (GoodsReceiptPoster).
  def self.approvable_quantities(lines, except_receipt_id:)
    claimed = claimed_quantities(lines, GoodsReceipt.confirmed.or(GoodsReceipt.approval_approved),
                                 except_receipt_id: except_receipt_id)
    lines.to_h { |line| [ line.id, quantity_left(line.quantity, claimed[line.id]) ] }
  end

  def self.quantity_left(ordered, claimed) = [ ordered - claimed.to_d, 0 ].max

  def self.claimed_quantities(lines, receipts, except_receipt_id: nil)
    return {} if lines.empty?

    relation = GoodsReceiptItem.joins(:goods_receipt).merge(GoodsReceipt.active).merge(receipts)
                               .where(purchase_request_item_id: lines.map(&:id))
    relation = relation.where.not(goods_receipt_id: except_receipt_id) if except_receipt_id
    relation.group(:purchase_request_item_id).sum(:quantity)
  end
  private_class_method :claimed_quantities

  # When goods_receipt_items (and its goods_receipt) are already preloaded —
  # the list/show pages always do this via .includes — sums in Ruby over the
  # loaded association instead of issuing a fresh query per item; falls back
  # to the grouped query only when called standalone (e.g. from a service).
  def received_quantity
    if goods_receipt_items.loaded?
      goods_receipt_items.select { |gri| gri.goods_receipt.confirmed? && gri.goods_receipt.active? }.sum(&:quantity)
    else
      self.class.received_quantities([ self ]).fetch(id, 0)
    end
  end

  def remaining_quantity
    self.class.quantity_left(quantity, received_quantity)
  end

  private

  def compute_total_cost
    self.total_cost = quantity.to_d * unit_price.to_d if quantity && unit_price
  end

  def product_in_same_business
    return if product.nil? || purchase_request&.business_id.nil?

    errors.add(:product_id, :invalid) if product.business_id != purchase_request.business_id
  end

  # The source warehouse id comes straight from form params and pre-fills the
  # receipt's warehouse — never trust one that belongs to another business (IP-1).
  def source_warehouse_in_same_business
    return if source_warehouse.nil? || purchase_request&.business_id.nil?

    errors.add(:source_warehouse_id, :other_business) if source_warehouse.business_id != purchase_request.business_id
  end

  def supplier_in_same_business
    return errors.add(:supplier_id, :invalid) if supplier_id.present? && supplier.nil?
    return if supplier.nil? || purchase_request&.business_id.nil?

    errors.add(:supplier_id, :invalid) if supplier.business_id != purchase_request.business_id
  end

  # A legacy request is locked to its one request-level supplier (every
  # receipt must use it), so a line on it can't name a different one.
  def supplier_matches_legacy_request_supplier
    legacy_id = purchase_request&.supplier_id
    return if legacy_id.nil? || supplier_id.nil? || supplier_id == legacy_id

    errors.add(:supplier_id, :must_match_purchase_request_supplier)
  end
end
