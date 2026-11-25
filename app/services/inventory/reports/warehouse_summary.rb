module Inventory
  module Reports
    # Per-warehouse snapshot for the overview: stock value, products in stock,
    # out-of-stock and low-stock counts, and period movement count. On-hand is
    # the ledger SUM per (product, warehouse) — the same signed sum StockLevels
    # uses — valued at each product's average cost; only active, tracked,
    # non-parent products count (as in Reports::CurrentStock), so the values
    # add up to the Current Stock report's total. Low stock per warehouse comes
    # from LowStockQuery's per-warehouse alerts.
    #
    # transit_warehouse: the business's system transit warehouse, given only
    # for a viewer of every warehouse (whose total includes it). Its stock —
    # goods dispatched but not yet received — is #transit_row, valued the same
    # way, so rows + transit_row add up to that total. Never an operational row.
    class WarehouseSummary
      Row = Struct.new(:warehouse, :stock_value, :products_in_stock, :out_of_stock, :low_stock,
                       :movements, keyword_init: true)

      def initialize(business, warehouses:, movement_summary:, low_stock_alerts:, transit_warehouse: nil)
        @business          = business
        @warehouses        = warehouses
        @transit_warehouse = transit_warehouse
        @movement_summary = movement_summary
        @low_stock_alerts = low_stock_alerts
      end

      def rows
        @rows ||= build_rows.reject { |row| row.warehouse == @transit_warehouse }
      end

      # The stock in transit between warehouses, or nil (scoped viewer / no
      # transit warehouse yet).
      def transit_row
        return nil if @transit_warehouse.nil?

        @transit_row ||= build_rows.find { |row| row.warehouse == @transit_warehouse }
      end

      def total_value = rows.sum(&:stock_value) + (transit_row&.stock_value || 0)

      private

      def build_rows
        @build_rows ||= begin
          warehouses = [ *@warehouses, @transit_warehouse ].compact
          ids      = warehouses.map(&:id)
          on_hand  = InventoryMovement.where(business_id: @business.id, warehouse_id: ids)
                                      .group(:warehouse_id, :product_id)
                                      .sum(Arel.sql(StockLevels::SIGNED))
          costs    = @business.products.active.inventory_tracked.pluck(:id, :average_cost_price).to_h
          low      = @low_stock_alerts.group_by(&:warehouse_id).transform_values(&:size)
          moves    = @movement_summary.counts_by_warehouse

          warehouses.map do |warehouse|
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
    end
  end
end
