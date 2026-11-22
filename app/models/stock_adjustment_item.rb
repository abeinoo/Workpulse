class StockAdjustmentItem < ApplicationRecord
  belongs_to :stock_adjustment
  belongs_to :product

  has_one :business, through: :stock_adjustment

  # Signed: positive increases stock, negative decreases it. Zero is meaningless.
  # A zero line is refused everywhere — manual adjustments, imports, opening
  # balances, stock counts — except a stock-count line that carries a counted
  # packaging difference (Decision 4: repackaging only through Stocktake):
  # it posts no movement, only count_correction packaging entries.
  validates :quantity_difference, numericality: { other_than: 0 }, unless: :packaging_only_count_line?
  validates :quantity_difference, numericality: true, if: :packaging_only_count_line?
  validate  :packaging_differences_only_on_stock_counts

  # { level id => package delta } with zero entries dropped.
  def packaging_level_differences
    (packaging_differences || {}).to_h.filter_map do |level_id, delta|
      delta = delta.to_i
      [ level_id.to_i, delta ] if delta.nonzero?
    end.to_h
  end

  def packaging_only_count_line?
    quantity_difference.to_d.zero? && packaging_level_differences.any? && stock_count_adjustment?
  end

  def stock_count_adjustment?
    stock_adjustment.present? && stock_adjustment.reason.to_s == "stock_count" && stock_adjustment.stock_count_id.present?
  end
  validate :product_in_same_business, if: :will_save_change_to_product_id?

  # Line product ids come straight from form params — never trust one that
  # belongs to another business (IP-1).
  def product_in_same_business
    return if product.nil? || stock_adjustment.nil? || stock_adjustment.business_id.nil?

    errors.add(:product_id, :other_business) if product.business_id != stock_adjustment.business_id
  end

  before_validation :compute_total_cost

  private

  def packaging_differences_only_on_stock_counts
    return if packaging_level_differences.empty? || stock_count_adjustment?

    errors.add(:packaging_differences, :stock_count_only)
  end

  def compute_total_cost
    self.unit_cost ||= 0
    self.total_cost = quantity_difference.to_d.abs * unit_cost.to_d if quantity_difference && unit_cost
  end
end
