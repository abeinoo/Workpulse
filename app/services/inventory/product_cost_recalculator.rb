module Inventory
  # Manual / batch recalculation of a product's moving average by replaying
  # its whole movement ledger in POSTING order (inventory_movements.id) with
  # exactly the rules Inventory::AverageCost applies at posting (W2): a
  # cost-bearing inflow blends; the reversal of a cost-bearing inflow (its
  # void) unblends; every other movement only moves the on-hand weight. The
  # replay therefore reproduces what posting would have produced; it never
  # reorders by document date and never drops a voided document from history.
  #
  # It is never run automatically — postings and voids keep the average
  # incrementally. It runs only on request (console / job), per product:
  #
  # * a replay whose running on-hand goes below zero STOPS for that product
  #   (Decision 19): nothing is written, no success record is made, and a
  #   Diagnostic is returned — no opening balance is invented, no movement
  #   skipped or reordered, no history changed;
  # * each product runs in its own savepoint, so one product's stop or error
  #   never affects another's write;
  # * a changed average is written through Inventory::AverageCost (audited,
  #   trigger manual_recalculation / batch_replay, one operation reference
  #   per run).
  class ProductCostRecalculator
    Diagnostic = Data.define(:product_id, :sku, :movement_id, :reason, :direction, :quantity, :occurred_on,
                             :posted_at, :source_type, :source_id, :balance_before, :balance_after, :ordering, :likely_cause)
    ProductResult = Data.define(:product_id, :status, :previous, :average, :diagnostic)

    ORDERING = "posting order (inventory_movements.id)".freeze

    def self.run(products, actor: nil, trigger: "batch_replay")
      operation_ref = "recalculation:#{SecureRandom.uuid}"
      Array(products).map { |product| new(product, actor: actor, trigger: trigger, operation_ref: operation_ref).call }
    end

    def initialize(product, actor: nil, trigger: "manual_recalculation", operation_ref: nil)
      @product       = product
      @actor         = actor
      @trigger       = trigger
      @operation_ref = operation_ref || "recalculation:#{SecureRandom.uuid}"
    end

    # Kept name for older callers; same as #call.
    def recompute! = call

    def call
      ActiveRecord::Base.transaction(requires_new: true) do
        StockAvailability.lock_products!([ @product.id ])
        replayed = replay
        next replayed if replayed.is_a?(ProductResult)

        outcome = AverageCost.new(@product, actor: @actor, operation_ref: @operation_ref)
                             .replace!(average: replayed, trigger: @trigger, metadata: { ordering: ORDERING })
        ProductResult.new(product_id: @product.id, status: outcome.changed ? :changed : :unchanged,
                          previous: outcome.previous, average: outcome.average, diagnostic: nil)
      end
    end

    private

    def replay
      running = 0.to_d
      average = @product.initial_cost_price.to_d
      movements.each do |movement|
        quantity = movement.quantity.to_d
        before   = running
        if movement.cost_bearing?
          total   = running + quantity
          average = ((running * average) + (quantity * movement.unit_cost.to_d)) / total if total.positive?
          running = total
        elsif movement.direction_in?
          running += quantity
        else
          remaining = running - quantity
          if cost_bearing_reversal?(movement) && remaining.positive?
            unblended = ((running * average) - (quantity * movement.unit_cost.to_d)) / remaining
            average = unblended unless unblended.negative?
          end
          running = remaining
        end
        return stopped(movement, before, running) if running.negative?
      end
      average
    end

    def movements
      @product.inventory_movements.includes(:source).order(:id).to_a
    end

    def cost_bearing_reversal?(movement)
      return false unless movement.reversal? && movement.direction_out?

      source = movement.source
      source.is_a?(GoodsReceipt) || (source.is_a?(StockAdjustment) && source.cost_bearing?)
    end

    def stopped(movement, before, after)
      diagnostic = Diagnostic.new(
        product_id: @product.id, sku: @product.sku, movement_id: movement.id, reason: movement.reason,
        direction: movement.direction, quantity: movement.quantity.to_d, occurred_on: movement.occurred_on,
        posted_at: movement.created_at, source_type: movement.source_type, source_id: movement.source_id,
        balance_before: before, balance_after: after, ordering: ORDERING, likely_cause: likely_cause(movement)
      )
      Rails.logger.warn("[ProductCostRecalculator] stopped product #{@product.id}: #{diagnostic.to_h}")
      ProductResult.new(product_id: @product.id, status: :stopped, previous: @product.average_cost_price.to_d,
                        average: nil, diagnostic: diagnostic)
    end

    # In posting order a negative balance cannot come from back-dating; it
    # means stock left before any recorded inflow (historical data, e.g. an
    # unlocked laundry consumption or a missing opening balance) or a void.
    def likely_cause(movement)
      return :voided_document if movement.reversal?
      return :historical_data if movement.direction_out?

      :unresolved
    end
  end
end
