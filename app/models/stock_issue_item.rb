class StockIssueItem < ApplicationRecord
  # touch: any line write (form, import resolver, poster) advances the parent's
  # updated_at — the edit form's lock_token (StockIssue#lock_token) — so a
  # stale form is detected even when only lines changed.
  belongs_to :stock_issue, touch: true
  belongs_to :product

  has_one :business, through: :stock_issue

  validates :quantity, numericality: { greater_than: 0 }
  validate  :product_is_transactable
  validate  :product_in_same_business

  def product_is_transactable
    return unless product
    errors.add(:product_id, :parent_not_allowed) if Product.where(parent_product_id: product.id).exists?
  end

  # Line product ids come straight from form params — never trust one that
  # belongs to another business.
  def product_in_same_business
    return if product.nil? || stock_issue.nil? || stock_issue.business_id.nil?

    errors.add(:product_id, :invalid) if product.business_id != stock_issue.business_id
  end

  before_validation :compute_total_cost

  # The line's cost under the inventory valuation method (moving weighted
  # average, see Inventory::ProductCostUpdater). Once the issue is posted,
  # unit_cost is the immutable snapshot Inventory::StockIssuePoster wrote to
  # the OUT movement — the ledger value, never re-derived. Before posting,
  # unit_cost is only a 0 placeholder, so the line is valued at the product's
  # current average cost as an estimate (re-snapshotted at posting). A product
  # with no cost history (average 0) has no estimate: nil, never a guess —
  # and never the selling price.
  def effective_unit_cost
    return unit_cost if cost_posted?
    return nil if product.nil?

    average = product.average_cost_price.to_d
    average.positive? ? average : nil
  end

  def effective_total_cost
    cost = effective_unit_cost
    cost && quantity.to_d * cost
  end

  def cost_posted?
    stock_issue&.issued? || false
  end

  def cost_unavailable?
    effective_unit_cost.nil?
  end

  private

  def compute_total_cost
    self.unit_cost ||= 0
    self.total_cost = quantity.to_d * unit_cost.to_d if quantity && unit_cost
  end
end
