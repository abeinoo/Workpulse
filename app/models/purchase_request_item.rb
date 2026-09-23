class PurchaseRequestItem < ApplicationRecord
  belongs_to :purchase_request
  belongs_to :product
  belongs_to :source_warehouse, class_name: "Warehouse", optional: true

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

  before_validation :compute_total_cost

  # Quantity actually posted so far — SUM over CONFIRMED, non-voided
  # GoodsReceiptItems only (a draft receipt hasn't received anything yet;
  # see GoodsReceipt#status / Voidable#active). Derived, never cached, so it
  # can never drift from the movements that actually happened.
  #
  # When goods_receipt_items (and its goods_receipt) are already preloaded —
  # the list/show pages always do this via .includes — sums in Ruby over the
  # loaded association instead of issuing a fresh query per item; falls back
  # to a direct SQL sum only when called standalone (e.g. from a service).
  def received_quantity
    if goods_receipt_items.loaded?
      goods_receipt_items.select { |gri| gri.goods_receipt.confirmed? && gri.goods_receipt.active? }.sum(&:quantity)
    else
      goods_receipt_items.joins(:goods_receipt).merge(GoodsReceipt.confirmed.active).sum(:quantity)
    end
  end

  def remaining_quantity
    [ quantity - received_quantity, 0 ].max
  end

  private

  def compute_total_cost
    self.total_cost = quantity.to_d * unit_price.to_d if quantity && unit_price
  end

  def product_in_same_business
    return if product.nil? || purchase_request&.business_id.nil?

    errors.add(:product_id, :invalid) if product.business_id != purchase_request.business_id
  end
end
