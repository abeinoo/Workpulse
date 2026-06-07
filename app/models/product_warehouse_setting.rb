# Warehouse-specific low-stock threshold + reorder quantity for a product.
# Overrides the product-level defaults so a branch warehouse can be alerted
# independently (e.g. a branch at zero stock triggers even when the main
# warehouse is well stocked). One row per (product, warehouse).
class ProductWarehouseSetting < ApplicationRecord
  belongs_to :product
  belongs_to :warehouse

  has_one :business, through: :product

  validates :warehouse_id, uniqueness: { scope: :product_id }
  validates :low_stock_level, :reorder_quantity,
            numericality: { greater_than_or_equal_to: 0 }
  validate :warehouse_in_same_business

  private

  def warehouse_in_same_business
    return if warehouse.nil? || product.nil?
    errors.add(:warehouse_id, :different_business) if warehouse.business_id != product.business_id
  end
end
