class GoodsReceiptItem < ApplicationRecord
  belongs_to :goods_receipt
  belongs_to :product

  has_one :business, through: :goods_receipt

  validates :quantity,  numericality: { greater_than: 0 }
  validates :unit_cost, numericality: { greater_than_or_equal_to: 0 }

  before_validation :compute_total_cost

  private

  def compute_total_cost
    self.total_cost = quantity.to_d * unit_cost.to_d if quantity && unit_cost
  end
end
