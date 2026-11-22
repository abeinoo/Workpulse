module Inventory
  # Kept for callers that blend a receipt into the moving average:
  #
  #   new_avg = (on_hand * avg + received_qty * unit_cost) / (on_hand + received_qty)
  #
  # Example (from spec): Hair Color received 10 @ 100, then 10 @ 120
  #   after #1: on_hand 0  -> avg = 100
  #   after #2: on_hand 10 -> avg = (10*100 + 10*120) / 20 = 110
  #
  # `last_purchase_price` always tracks the most recent receipt's unit cost.
  # The write, its 8-dp rounding and its audit record live in
  # Inventory::AverageCost.
  class ProductCostUpdater
    def initialize(product, actor: nil, owner: :lookup, current_average: nil)
      @product         = product
      @actor           = actor
      @owner           = owner
      @current_average = current_average
    end

    # on_hand_before: product's total on-hand *before* this receipt quantity.
    def apply_receipt(quantity:, unit_cost:, on_hand_before:, source: nil, movement: nil)
      AverageCost.new(@product, actor: @actor, owner: @owner, current_average: @current_average).apply_inflow!(
        quantity: quantity, unit_cost: unit_cost, on_hand_before: on_hand_before,
        trigger: "receipt_posted", source: source, movement: movement, last_purchase: true
      )
    end
  end
end
