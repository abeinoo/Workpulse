class StockAdjustment < ApplicationRecord
  include ImmutableDocument
  include Voidable

  belongs_to :business
  belongs_to :warehouse
  belongs_to :created_by, class_name: "User", optional: true

  has_many :items, class_name: "StockAdjustmentItem", dependent: :destroy
  has_many :inventory_movements, as: :source, dependent: :destroy

  # The physical count that generated this adjustment, if any. A count may own
  # several adjustments over its life (approve → reopen voids → approve again),
  # at most one active — DB partial unique index
  # index_stock_adjustments_one_active_per_stock_count.
  belongs_to :stock_count, optional: true, inverse_of: :stock_adjustments

  accepts_nested_attributes_for :items,
                                allow_destroy: true,
                                reject_if:     ->(attrs) { attrs[:product_id].blank? }

  REASONS = %w[opening_balance stock_count damaged lost expired manual_correction].freeze
  # Reasons a person may choose for a manual adjustment — "stock_count" is
  # posted only by a stock count approval (see stock_count_reason_matches_link).
  MANUAL_REASONS = (REASONS - %w[stock_count]).freeze
  enum :reason, REASONS.index_with(&:itself)

  validates :adjustment_number, presence: true,
                                uniqueness: { scope: :business_id, case_sensitive: false }
  validates :adjusted_on, presence: true
  validates :reason, presence: true
  validate  :has_at_least_one_item
  validate  :opening_balance_lines_require_cost
  validate  :warehouse_in_same_business, if: :will_save_change_to_warehouse_id?
  # Only a stock count's approval may post a "stock_count" adjustment, and it
  # must name its count — a manual adjustment can never pose as a count.
  validate  :stock_count_reason_matches_link, on: :create

  scope :for_business, ->(business) { where(business: business) }
  scope :recent,       -> { order(adjusted_on: :desc, id: :desc) }

  # Opening-balance lines establish/blend the product's average cost; all other
  # reasons only correct quantity (valued at the current average).
  def cost_bearing?
    opening_balance?
  end

  # ── Value impact (signed, valued at each line's frozen unit-cost snapshot) ──
  # Negative lines are shortages (stock lost), positive lines overages (gained).
  def line_value(item) = item.quantity_difference.to_d * item.unit_cost.to_d

  def shortage_value = items.select { |i| i.quantity_difference.negative? }.sum { |i| line_value(i) }
  def overage_value  = items.select { |i| i.quantity_difference.positive? }.sum { |i| line_value(i) }
  def net_value      = items.sum { |i| line_value(i) }

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

  def stock_count_reason_matches_link
    if stock_count?
      errors.add(:reason, :stock_count_requires_count) if stock_count_id.nil?
    elsif stock_count_id.present?
      errors.add(:reason, :count_link_requires_stock_count_reason)
    end
    return if stock_count.nil?

    errors.add(:stock_count_id, :other_business) if stock_count.business_id != business_id
    errors.add(:warehouse_id, :differs_from_stock_count) if stock_count.warehouse_id != warehouse_id
  end

  # The warehouse id comes straight from form params — never trust one that
  # belongs to another business (IP-1).
  def warehouse_in_same_business
    return if warehouse.nil? || business_id.nil?

    errors.add(:warehouse_id, :other_business) if warehouse.business_id != business_id
  end
end
