module Inventory
  # Recomputes a product's costing after a goods receipt, using the moving
  # weighted-average method at the product level (across all warehouses):
  #
  #   new_avg = (on_hand * avg + received_qty * unit_cost) / (on_hand + received_qty)
  #
  # Example (from spec): Hair Color received 10 @ 100, then 10 @ 120
  #   after #1: on_hand 0  -> avg = 100
  #   after #2: on_hand 10 -> avg = (10*100 + 10*120) / 20 = 110
  #
  # `last_purchase_price` always tracks the most recent receipt's unit cost.
  # Must run AFTER the IN movement is persisted so `current_stock` includes it;
  # callers pass the pre-receipt on-hand explicitly to avoid that ordering trap.
  class ProductCostUpdater
    def initialize(product)
      @product = product
    end

    # on_hand_before: product's total on-hand *before* this receipt quantity.
    def apply_receipt(quantity:, unit_cost:, on_hand_before:)
      quantity  = quantity.to_d
      unit_cost = unit_cost.to_d
      return if quantity.zero?

      prior_qty = on_hand_before.to_d
      prior_avg = @product.average_cost_price.to_d
      new_total = prior_qty + quantity

      new_avg = if new_total.positive?
        ((prior_qty * prior_avg) + (quantity * unit_cost)) / new_total
      else
        prior_avg
      end

      @product.update!(
        average_cost_price:  new_avg,
        last_purchase_price: unit_cost
      )
    end
  end
end
