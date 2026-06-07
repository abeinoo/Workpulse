class StockCountItem < ApplicationRecord
  belongs_to :stock_count
  belongs_to :product

  has_one :business, through: :stock_count

  validates :counted_quantity, numericality: { greater_than_or_equal_to: 0 }
  validates :product_id, uniqueness: { scope: :stock_count_id }

  before_validation :compute_difference

  private

  # difference = counted − system. Positive means surplus to add, negative a
  # shortfall to remove. Recomputed from the live system quantity at post time.
  def compute_difference
    self.system_quantity  ||= 0
    self.counted_quantity ||= 0
    self.difference = counted_quantity.to_d - system_quantity.to_d
  end
end
