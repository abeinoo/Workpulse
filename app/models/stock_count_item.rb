class StockCountItem < ApplicationRecord
  belongs_to :stock_count
  belongs_to :product

  has_one :business, through: :stock_count

  # Counted quantity is whole units only; blank (nil) means "not counted yet".
  # (only_integer can't be used: the value lives in a decimal column, so it comes
  # back as BigDecimal "n.0" and the integer string-regex would reject every value;
  # we instead reject genuinely fractional inputs while accepting whole values.)
  validates :counted_quantity, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
  validate  :counted_quantity_is_whole
  validates :product_id, uniqueness: { scope: :stock_count_id }
  validate  :product_is_transactable

  def product_is_transactable
    return unless product
    errors.add(:product_id, :parent_not_allowed) if Product.where(parent_product_id: product.id).exists?
  end

  before_validation :compute_difference

  # A row is "counted" once a quantity has been entered — including an explicit
  # zero. A blank (nil) counted quantity means it has not been counted yet.
  def counted?
    !counted_quantity.nil?
  end

  private

  def counted_quantity_is_whole
    return if counted_quantity.nil?
    errors.add(:counted_quantity, :not_an_integer) unless counted_quantity == counted_quantity.to_i
  end

  # difference = counted − system (nil while uncounted). Positive means surplus to
  # add, negative a shortfall to remove. Recomputed from the live system quantity
  # at approval time.
  def compute_difference
    self.system_quantity ||= 0
    self.difference = counted? ? counted_quantity.to_d - system_quantity.to_d : nil
  end
end
