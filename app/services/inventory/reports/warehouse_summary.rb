module Inventory
  module Reports
    # Per-warehouse snapshot for the overview: stock value, products in stock,
    # out-of-stock and low-stock counts, and period movement count. On-hand is
    # the ledger SUM per (product, warehouse) — the same signed sum StockLevels
    # uses — valued at each product's average cost; only active, tracked,
    # non-parent products count (as in Reports::CurrentStock), so the values
    # add up to the Current Stock report's total. Low stock per warehouse comes
    # from LowStockQuery's per-warehouse alerts.
    class WarehouseSummary
      Row = Struct.new(:warehouse, :stock_value, :products_in_stock, :out_of_stock, :low_stock,
                       :movements, keyword_init: true)

      def initialize(business, warehouses:, movement_summary:, low_stock_alerts:)
        @business         = business
        @warehouses       = warehouses
        @movement_summary = movement_summary
        @low_stock_alerts = low_stock_alerts
      end

      def rows
        @rows ||= begin
          ids      = @warehouses.map(&:id)
          on_hand  = InventoryMovement.where(business_id: @business.id, warehouse_id: ids)
                                      .group(:warehouse_id, :product_id)
                                      .sum(Arel.sql(StockLevels::SIGNED))
          costs    = @business.products.active.inventory_tracked.non_parent.pluck(:id, :average_cost_price).to_h
          low      = @low_stock_alerts.reject(&:total?).group_by(&:warehouse_id).transform_values(&:size)
          moves    = @movement_summary.counts_by_warehouse

          @warehouses.map do |warehouse|
            stock = on_hand.select { |(wid, pid), _| wid == warehouse.id && costs.key?(pid) }
            Row.new(
              warehouse:         warehouse,
              stock_value:       stock.sum { |(_, pid), qty| qty * costs[pid] },
              products_in_stock: stock.count { |_, qty| qty.positive? },
              out_of_stock:      stock.count { |_, qty| qty <= 0 },
              low_stock:         low[warehouse.id] || 0,
              movements:         moves[warehouse.id] || 0
            )
          end
        end
      end

      def total_value = rows.sum(&:stock_value)
    end
  end
end
