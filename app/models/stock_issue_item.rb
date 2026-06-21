class StockIssueItem < ApplicationRecord
  belongs_to :stock_issue
  belongs_to :product

  has_one :business, through: :stock_issue

  validates :quantity, numericality: { greater_than: 0 }
  validate  :product_is_transactable

  def product_is_transactable
    return unless product
    errors.add(:product_id, :parent_not_allowed) if Product.where(parent_product_id: product.id).exists?
  end

  before_validation :compute_total_cost

  private

  def compute_total_cost
    self.unit_cost ||= 0
    self.total_cost = quantity.to_d * unit_cost.to_d if quantity && unit_cost
  end
end
