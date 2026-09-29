module Inventory
  module Reports
    # Low Stock report rows: LowStockQuery's alerts (per-warehouse thresholds,
    # falling back to the product-level default) valued for purchasing.
    # Suggested purchase quantity is the configured reorder quantity for that
    # alert (per-warehouse setting, else the product default) — the same
    # number the dashboard's purchasing table and purchase-request review use.
    class LowStock
      Row = Struct.new(:alert, :unit_cost, :suggested_value, keyword_init: true) do
        delegate :product, :warehouse_id, :warehouse_name, :on_hand, :low_stock_level, :total?, to: :alert

        def suggested_quantity = alert.reorder_quantity
        def priced?            = unit_cost.present? && unit_cost.positive?
        def supplier           = product.default_supplier
      end

      def self.rows_for(alerts)
        alerts.map do |alert|
          price = alert.product.average_cost_price
          priced = price.present? && price.positive?
          Row.new(alert: alert, unit_cost: price,
                  suggested_value: priced ? alert.reorder_quantity.to_d * price : 0)
        end
      end

      def initialize(business, warehouse_ids: nil)
        @business      = business
        @warehouse_ids = warehouse_ids
      end

      def rows
        @rows ||= self.class.rows_for(LowStockQuery.new(@business, warehouse_ids: @warehouse_ids).alerts)
      end

      def total_suggested_value = rows.sum(&:suggested_value)
    end
  end
end
