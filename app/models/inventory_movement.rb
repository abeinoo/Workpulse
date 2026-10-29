# Immutable ledger entry — the single source of truth for stock quantities.
# Current stock for a (product, warehouse) is SUM(in) - SUM(out) over these rows.
# Rows are created by the posting services (GoodsReceiptPoster / StockIssuePoster)
# and an opening_balance import; they are never edited by hand.
class InventoryMovement < ApplicationRecord
  belongs_to :business
  belongs_to :product
  belongs_to :warehouse
  # Branch that consumed the stock (carried from the stock issue). Only OUT/
  # stock_issue movements set it; receipts, transfers and adjustments leave it
  # NULL and are unattributed in branch profitability — by design.
  belongs_to :branch, optional: true
  belongs_to :source, polymorphic: true, optional: true

  DIRECTIONS = %w[in out].freeze
  REASONS    = %w[goods_receipt stock_issue opening_balance adjustment
                  transfer_in transfer_out reversal laundry_consumption].freeze

  # Reasons whose IN movements establish/blend the product's moving-average cost.
  # Everything else (issues, transfers, count corrections, reversals) only moves
  # quantity and is valued at the current average.
  COST_BEARING_REASONS = %w[goods_receipt opening_balance].freeze

  enum :direction, { in: "in", out: "out" }, prefix: true
  enum :reason, {
    goods_receipt:   "goods_receipt",
    stock_issue:     "stock_issue",
    opening_balance: "opening_balance",
    adjustment:      "adjustment",
    transfer_in:     "transfer_in",
    transfer_out:    "transfer_out",
    reversal:        "reversal",
    # Material consumed by a completed LaundryBatch, posted OUT of the Laundry
    # Warehouse. Valued at the current average cost like stock_issue; never
    # cost-bearing (see COST_BEARING_REASONS) and never re-averages the product.
    laundry_consumption: "laundry_consumption"
  }

  def cost_bearing?
    direction_in? && COST_BEARING_REASONS.include?(reason)
  end

  validates :quantity, numericality: { greater_than: 0 }
  validates :unit_cost, numericality: { greater_than_or_equal_to: 0 }
  validates :occurred_on, presence: true
  # Last line of defence for every posting path (IP-1): stock sums are keyed by
  # product and warehouse alone, so a row naming another business's product or
  # warehouse would silently change that business's on-hand and valuation. The
  # documents validate their own references first; this refuses the write if
  # any path ever skips them.
  validate  :references_in_same_business, on: :create

  scope :for_business, ->(business) { where(business: business) }
  scope :chronological, -> { order(:occurred_on, :id) }
  # Consumption figures (cost of stock consumed by branches) are NOT a plain
  # scope: a voided stock issue must net out against its reversal. Use
  # Inventory::ConsumptionLedger — the one place that definition lives.
  scope :for_branch,  ->(branch_id) { where(branch_id: branch_id) if branch_id.present? }
  scope :occurred_between, ->(from, to) { where(occurred_on: from..to) }

  # Signed quantity: positive for IN, negative for OUT — used by stock sums.
  def signed_quantity
    direction_in? ? quantity : -quantity
  end

  private

  def references_in_same_business
    return if business_id.nil?

    errors.add(:product_id, :other_business)   if product   && product.business_id   != business_id
    errors.add(:warehouse_id, :other_business) if warehouse && warehouse.business_id != business_id
  end
end
