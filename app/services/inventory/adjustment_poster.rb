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
  #   The average moves at posting time only (W2, Inventory::AverageCost,
  #   audited); nothing is replayed from history.
  #
  # Packaging: a decrease takes loose content first, then opens the fewest
  # packages; an increase arrives loose. A stock-count line carries the
  # counted packaging difference (packaging_differences: { level id => Δ }):
  # its count_correction entries replace the recorded packaging, and a line
  # whose base difference is zero posts no movement at all (Decision 4).
  # Removals protect approved reservations (on-hand − removal >= reserved).
  #
  # Concurrency: the products are row-locked (StockAvailability.lock_products!,
  # the same FOR UPDATE lock stock issues and transfers take) BEFORE the
  # on-hand check, inside the transaction that writes the movements — so a
  # concurrent issue, transfer, void or second adjustment of the same product
  # can't consume the stock between the check and the OUT movement.
  #
  # Opening-balance increases into a product/warehouse pair whose availability
  # is Inactive are refused (Inventory::IncomingAvailabilityGuard) — this also
  # covers the product importer's opening stock. Every other adjustment
  # (stock count corrections, damage, loss, manual corrections, either sign)
  # stays allowed: it records physical reality and carries a reason.
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
      return failure if foreign_references?

      result = ActiveRecord::Base.transaction do
        StockAvailability.lock_products!(@adjustment.items.reject(&:marked_for_destruction?).map(&:product_id))
        value_items
        next failure unless opening_balance_allowed?
        next failure unless availability_ok?
        next failure unless reservations_protected?

        @packaging = Packaging::Session.new(business: @adjustment.business, product_ids: @adjustment.items.map(&:product_id),
                                            warehouse_ids: [ @adjustment.warehouse_id ])

        @adjustment.adjustment_number = NumberSequencer.new(@adjustment.business, :stock_adjustment).next_number if @adjustment.adjustment_number.blank?

        raise ActiveRecord::Rollback unless @adjustment.save

        @adjustment.items.each { |item| post_item(item) }
        audit_posting
        Result.new(ok: true, adjustment: @adjustment)
      end

      result || failure
    rescue AuditLoggable::AuditWriteFailed
      @adjustment.errors.add(:base, :average_cost_audit_failed)
      failure
    rescue Packaging::Refused => e
      @adjustment.errors.add(:base, :packaging_refused, message: e.message)
      failure
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
          lines: @adjustment.items.map do |i|
            { product_id: i.product_id, quantity_difference: i.quantity_difference.to_s,
              packaging_differences: i.packaging_differences.presence }.compact
          end
        }.compact
      )
    end

    def value_items
      averages = StockAvailability.locked_averages(@adjustment.items.map(&:product_id))
      @adjustment.items.each do |item|
        next if item.product.nil?

        # Opening-balance increases keep the user-supplied unit cost as-is — it is
        # mandatory (enforced by StockAdjustment validation), never inferred.
        # Every other line is valued at the product's current average cost.
        if @adjustment.cost_bearing? && item.quantity_difference.to_d.positive?
          next
        end

        item.unit_cost = averages.fetch(item.product_id, item.product.average_cost_price)
      end
    end

    def reservations_protected?
      removals = @adjustment.items.reject(&:marked_for_destruction?)
                            .select { |item| item.product_id && item.quantity_difference.to_d.negative? }
                            .group_by(&:product_id)
                            .transform_values { |items| items.sum { |item| item.quantity_difference.to_d.abs } }
      StockAvailability.protect_reservations!(@adjustment, warehouse: @adjustment.warehouse, removals: removals)
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

    # Runs under the product locks; locks the pair rows last.
    def opening_balance_allowed?
      return true unless @adjustment.cost_bearing?

      incoming = @adjustment.items.reject(&:marked_for_destruction?)
                            .select { |item| item.quantity_difference.to_d.positive? }
      guard = IncomingAvailabilityGuard.new(warehouse_id: @adjustment.warehouse_id, product_ids: incoming.map(&:product_id))
      !guard.refuse!(@adjustment)
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
                               available: StockAvailability.format_quantity(available),
                               requested: StockAvailability.format_quantity(requested))
      end
      ok
    end

    def post_item(item)
      diff      = item.quantity_difference.to_d
      direction = diff.positive? ? :in : :out
      reason    = (@adjustment.cost_bearing? && diff.positive?) ? :opening_balance : :adjustment
      on_hand_before = item.product.current_stock if reason == :opening_balance

      movement = if diff.nonzero?
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

      @packaging.apply!(product: item.product, warehouse_id: @adjustment.warehouse_id, source: @adjustment,
                        occurred_on: @adjustment.adjusted_on, movement: movement) do |plan|
        corrections = item.packaging_level_differences
        if corrections.any?
          plan.adjust_total(diff)
          corrections.each { |level_id, delta| plan.correct(plan.structure.level(level_id)&.position || -1, delta) }
        elsif diff.positive?
          plan.add_base(diff)
        else
          plan.take_base(diff.abs)
        end
      end

      return unless reason == :opening_balance

      AverageCost.new(item.product, actor: @adjustment.created_by).apply_inflow!(
        quantity: diff, unit_cost: item.unit_cost, on_hand_before: on_hand_before,
        trigger: "opening_balance_posted", source: @adjustment, movement: movement
      )
    end
  end
end
