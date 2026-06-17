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
                  transfer_in transfer_out reversal].freeze

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
    reversal:        "reversal"
  }

  def cost_bearing?
    direction_in? && COST_BEARING_REASONS.include?(reason)
  end

  validates :quantity, numericality: { greater_than: 0 }
  validates :unit_cost, numericality: { greater_than_or_equal_to: 0 }
  validates :occurred_on, presence: true

  scope :for_business, ->(business) { where(business: business) }
  scope :chronological, -> { order(:occurred_on, :id) }
  # Stock consumed out of branches — the cost-of-consumption rows that branch
  # profitability sums (quantity × unit_cost). Source-agnostic: a future Fresha
  # importer writing the same OUT/stock_issue movements is picked up unchanged.
  scope :consumption, -> { where(direction: "out", reason: "stock_issue") }
  scope :for_branch,  ->(branch_id) { where(branch_id: branch_id) if branch_id.present? }
  scope :occurred_between, ->(from, to) { where(occurred_on: from..to) }

  # Signed quantity: positive for IN, negative for OUT — used by stock sums.
  def signed_quantity
    direction_in? ? quantity : -quantity
  end
end
