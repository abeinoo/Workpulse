module Inventory
  # Recomputes a product's average + last-purchase cost from scratch by replaying
  # its entire NON-VOIDED movement history in chronological order.
  #
  # Why a full replay (vs. incremental like ProductCostUpdater): moving-average
  # cost is path-dependent — later receipts and intervening issues are blended in
  # — so reversing a historical document cannot be undone by simple subtraction.
  # Replaying the surviving history yields exactly the cost "as if the voided
  # document never happened".
  #
  # Movements belonging to a voided document (both the originals AND their
  # reversals) are excluded, so a voided doc has zero effect on cost. Live stock,
  # by contrast, is the full ledger sum where original + reversal net to zero — so
  # the two stay consistent.
  #
  # The average only moves on cost-bearing INs (goods_receipt / opening_balance);
  # every other movement just advances the running on-hand used as the weight.
  class ProductCostRecalculator
    def initialize(product)
      @product = product
    end

    def recompute!
      running_qty   = 0.to_d
      average       = @product.initial_cost_price.to_d
      last_purchase = nil

      live_movements.each do |movement|
        qty = movement.quantity.to_d

        if movement.direction_in?
          if movement.cost_bearing?
            new_total = running_qty + qty
            average   = ((running_qty * average) + (qty * movement.unit_cost.to_d)) / new_total if new_total.positive?
            last_purchase = movement.unit_cost if movement.reason == "goods_receipt"
          end
          running_qty += qty
        else
          running_qty -= qty
        end
      end

      @product.update!(average_cost_price: average, last_purchase_price: last_purchase)
    end

    private

    # All of the product's movements whose owning document is not voided,
    # in posting order. Movements with no document source are always included.
    def live_movements
      @product.inventory_movements
              .includes(:source)
              .order(:occurred_on, :id)
              .reject { |m| m.source.respond_to?(:voided?) && m.source.voided? }
    end
  end
end
