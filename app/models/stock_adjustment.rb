class StockAdjustment < ApplicationRecord
  include ImmutableDocument
  include Voidable

  belongs_to :business
  belongs_to :warehouse
  belongs_to :created_by, class_name: "User", optional: true

  has_many :items, class_name: "StockAdjustmentItem", dependent: :destroy
  has_many :inventory_movements, as: :source, dependent: :destroy

  accepts_nested_attributes_for :items,
                                allow_destroy: true,
                                reject_if:     ->(attrs) { attrs[:product_id].blank? }

  REASONS = %w[opening_balance stock_count damaged lost expired manual_correction].freeze
  enum :reason, REASONS.index_with(&:itself)

  validates :adjustment_number, presence: true,
                                uniqueness: { scope: :business_id, case_sensitive: false }
  validates :adjusted_on, presence: true
  validates :reason, presence: true
  validate  :has_at_least_one_item
  validate  :opening_balance_lines_require_cost

  scope :for_business, ->(business) { where(business: business) }
  scope :recent,       -> { order(adjusted_on: :desc, id: :desc) }

  # Opening-balance lines establish/blend the product's average cost; all other
  # reasons only correct quantity (valued at the current average).
  def cost_bearing?
    opening_balance?
  end

  # Compensating movements that undo this adjustment: a positive line (which
  # increased stock) is reversed with an OUT, a negative line with an IN.
  def reversal_entries
    items.map do |item|
      removing = item.quantity_difference.positive?
      { product: item.product, warehouse: warehouse,
        direction: removing ? :out : :in,
        quantity:  item.quantity_difference.abs, unit_cost: item.unit_cost }
    end
  end

  private

  def has_at_least_one_item
    errors.add(:base, :no_items) if items.reject(&:marked_for_destruction?).empty?
  end

  # Opening balances must always carry a unit cost — they establish the product's
  # valuation and may never be posted cost-free.
  def opening_balance_lines_require_cost
    return unless opening_balance?

    items.reject(&:marked_for_destruction?).each do |item|
      next unless item.quantity_difference.to_d.positive?
      errors.add(:base, :opening_balance_needs_cost, product: item.product&.name) if item.unit_cost.to_d <= 0
    end
  end
end
