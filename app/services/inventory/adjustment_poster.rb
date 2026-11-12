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
  #
  # Concurrency: the products are row-locked (StockAvailability.lock_products!,
  # the same FOR UPDATE lock stock issues and transfers take) BEFORE the
  # on-hand check, inside the transaction that writes the movements — so a
  # concurrent issue, transfer, void or second adjustment of the same product
  # can't consume the stock between the check and the OUT movement.
  #
  # When called inside a caller's transaction (Inventory::StockCountApprover),
  # a failure returns ok: false and the caller rolls back.
  class AdjustmentPoster
    include AuditLoggable

    Result = Struct.new(:ok, :adjustment, keyword_init: true) do
      def ok? = ok
    end

    def initialize(adjustment)
      @adjustment = adjustment
    end

    def call
      value_items
      return failure if foreign_references?

      result = ActiveRecord::Base.transaction do
        StockAvailability.lock_products!(@adjustment.items.reject(&:marked_for_destruction?).map(&:product_id))
        next failure unless availability_ok?

        @adjustment.adjustment_number = NumberSequencer.new(@adjustment.business, :stock_adjustment).next_number if @adjustment.adjustment_number.blank?

        raise ActiveRecord::Rollback unless @adjustment.save

        @adjustment.items.each { |item| post_item(item) }
        @adjustment.items.map(&:product).uniq.each { |product| ProductCostRecalculator.new(product).recompute! }
        audit_posting
        Result.new(ok: true, adjustment: @adjustment)
      end

      result || failure
    end

    private

    def failure
      Result.new(ok: false, adjustment: @adjustment)
    end

    def audit_posting
      return if @adjustment.created_by.nil?

      log_audit(
        actor: @adjustment.created_by, auditable: @adjustment, action: "post",
        metadata: {
          adjustment_number: @adjustment.adjustment_number,
          reason:            @adjustment.reason,
          warehouse_id:      @adjustment.warehouse_id,
          stock_count_id:    @adjustment.stock_count_id,
          stock_count_number: @adjustment.stock_count&.count_number,
          lines: @adjustment.items.map { |i| { product_id: i.product_id, quantity_difference: i.quantity_difference.to_s } }
        }.compact
      )
    end

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

    # A warehouse or product of another business is refused before availability
    # reads (and reports) that business's on-hand (IP-1). Any other validation
    # error is left for #save to report, exactly as before.
    def foreign_references?
      @adjustment.valid?
      return true if @adjustment.errors.any? { |error| error.type == :other_business }

      @adjustment.errors.clear
      false
    end

    # Negative lines remove stock — block any that exceed the warehouse on-hand.
    # Runs under the product locks taken in #call.
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
