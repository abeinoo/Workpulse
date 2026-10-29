class StockAdjustmentItem < ApplicationRecord
  belongs_to :stock_adjustment
  belongs_to :product

  has_one :business, through: :stock_adjustment

  # Signed: positive increases stock, negative decreases it. Zero is meaningless.
  validates :quantity_difference,
            numericality: { other_than: 0 }
  validate  :product_is_transactable
  validate  :product_in_same_business, if: :will_save_change_to_product_id?

  def product_is_transactable
    return unless product
    errors.add(:product_id, :parent_not_allowed) if Product.where(parent_product_id: product.id).exists?
  end

  # Line product ids come straight from form params — never trust one that
  # belongs to another business (IP-1).
  def product_in_same_business
    return if product.nil? || stock_adjustment.nil? || stock_adjustment.business_id.nil?

    errors.add(:product_id, :other_business) if product.business_id != stock_adjustment.business_id
  end

  before_validation :compute_total_cost

  private

  def compute_total_cost
    self.unit_cost ||= 0
    self.total_cost = quantity_difference.to_d.abs * unit_cost.to_d if quantity_difference && unit_cost
  end
end
