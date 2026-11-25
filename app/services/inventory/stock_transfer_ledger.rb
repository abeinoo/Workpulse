module Inventory
  # The movement legs of a via-transit stock transfer — the ONLY writer of
  # transit_in / transit_out / transfer_loss / transfer_return movements. Every
  # leg is an ordinary InventoryMovement (the ledger stays the single source of
  # stock), valued at the line's dispatch-time unit cost (StockTransferItem#unit_cost,
  # fixed at dispatch) and dated on the Business Day of the step:
  #
  #   dispatch          source  OUT transfer_out   + transit IN  transit_in
  #   receipt           transit OUT transit_out    + destination IN transfer_in
  #   return to source  transit OUT transit_out    + source IN   transfer_return
  #   write-off         transit OUT transfer_loss
  #
  # None is cost-bearing (InventoryMovement::COST_BEARING_REASONS), so the
  # moving average never changes; the business total changes only by a
  # write-off. Callers run inside their transaction, after the transfer row and
  # Product row locks.
  module StockTransferLedger
    module_function

    def leg!(transfer, item:, warehouse:, direction:, reason:, quantity:, occurred_on:)
      transfer.inventory_movements.create!(
        business: transfer.business, product: item.product, warehouse: warehouse, direction: direction,
        reason: reason, quantity: quantity, unit_cost: item.unit_cost, occurred_on: occurred_on
      )
    end

    # Stock of the given products currently in the transit warehouse.
    def transit_on_hand(transit_warehouse, product_ids)
      return {} if transit_warehouse.nil?

      StockAvailability.on_hand_by(warehouse_ids: transit_warehouse.id, product_ids: product_ids)
                       .transform_keys(&:last)
    end
  end
end
