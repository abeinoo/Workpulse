module Inventory
  # Posts an inventory adjustment: validates that negative lines can't drive a
  # warehouse below zero, values each line, then records one ledger movement per
  # line (positive -> IN, negative -> OUT) and recomputes affected product costs.
  #
  # Valuation:
  #   * opening_balance lines are cost-bearing — they use the supplied unit cost
  #     (falling back to the product's current average, then its initial cost),
  #     and blend into the moving average via the recompute.
  #   * every other reason is valued at the product's current average cost and
  #     leaves the average unchanged (a pure quantity correction).
  class AdjustmentPoster
    Result = Struct.new(:ok, :adjustment, keyword_init: true) do
      def ok? = ok
    end

    def initialize(adjustment)
      @adjustment = adjustment
    end

    def call
      value_items
      unless availability_ok?
        return Result.new(ok: false, adjustment: @adjustment)
      end

      ActiveRecord::Base.transaction do
        @adjustment.adjustment_number = NumberSequencer.new(@adjustment.business, :stock_adjustment).next_number if @adjustment.adjustment_number.blank?

        raise ActiveRecord::Rollback unless @adjustment.save

        @adjustment.items.each { |item| post_item(item) }
        @adjustment.items.map(&:product).uniq.each { |product| ProductCostRecalculator.new(product).recompute! }
        return Result.new(ok: true, adjustment: @adjustment)
      end

      Result.new(ok: false, adjustment: @adjustment)
    end

    private

    def value_items
      @adjustment.items.each do |item|
        next if item.product.nil?

        # Opening-balance increases keep the user-supplied unit cost as-is — it is
        # mandatory (enforced by StockAdjustment validation), never inferred.
        # Every other line is valued at the product's current average cost.
        if @adjustment.cost_bearing? && item.quantity_difference.to_d.positive?
          next
        end

        item.unit_cost = item.product.average_cost_price
      end
    end

    # Negative lines remove stock — block any that exceed the warehouse on-hand.
    def availability_ok?
      ok = true
      @adjustment.items.reject(&:marked_for_destruction?)
                 .select { |item| item.quantity_difference.to_d.negative? }
                 .group_by(&:product_id).each do |_product_id, items|
        product = items.first.product
        next if product.nil?

        requested = items.sum { |item| item.quantity_difference.to_d.abs }
        available = product.stock_in(@adjustment.warehouse)
        next if requested <= available

        ok = false
        @adjustment.errors.add(:base, :insufficient_stock,
                               product: product.name, sku: product.sku,
                               available: available.to_s, requested: requested.to_s)
      end
      ok
    end

    def post_item(item)
      diff      = item.quantity_difference.to_d
      direction = diff.positive? ? :in : :out
      reason    = (@adjustment.cost_bearing? && diff.positive?) ? :opening_balance : :adjustment

      @adjustment.inventory_movements.create!(
        business:    @adjustment.business,
        product:     item.product,
        warehouse:   @adjustment.warehouse,
        direction:   direction,
        reason:      reason,
        quantity:    diff.abs,
        unit_cost:   item.unit_cost,
        occurred_on: @adjustment.adjusted_on
      )
    end
  end
end
