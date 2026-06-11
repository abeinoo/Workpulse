class StockTransferItem < ApplicationRecord
  belongs_to :stock_transfer
  belongs_to :product

  has_one :business, through: :stock_transfer

  validates :quantity, numericality: { greater_than: 0 }

  before_validation :compute_total_cost

  private

  def compute_total_cost
    self.unit_cost ||= 0
    self.total_cost = quantity.to_d * unit_cost.to_d if quantity && unit_cost
  end
end
