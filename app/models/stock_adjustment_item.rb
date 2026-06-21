class StockAdjustmentItem < ApplicationRecord
  belongs_to :stock_adjustment
  belongs_to :product

  has_one :business, through: :stock_adjustment

  # Signed: positive increases stock, negative decreases it. Zero is meaningless.
  validates :quantity_difference,
            numericality: { other_than: 0 }
  validate  :product_is_transactable

  def product_is_transactable
    return unless product
    errors.add(:product_id, :parent_not_allowed) if Product.where(parent_product_id: product.id).exists?
  end

  before_validation :compute_total_cost

  private

  def compute_total_cost
    self.unit_cost ||= 0
    self.total_cost = quantity_difference.to_d.abs * unit_cost.to_d if quantity_difference && unit_cost
  end
end
