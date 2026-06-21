module Inventory
  module Reports
    # Current Stock report: on-hand, last cost and stock value per product,
    # restricted to a set of warehouses (nil = all).
    class CurrentStock
      Row = Struct.new(:product, :on_hand, :last_cost, :unit_cost, :stock_value, keyword_init: true)

      def initialize(business, warehouse_ids: nil)
        @business      = business
        @warehouse_ids = warehouse_ids
      end

      def rows
        totals = StockLevels.totals_for(@business, warehouse_ids: @warehouse_ids)
        # Exclude parent products — they carry no inventory; their children appear
        # as their own rows and reflect the real stock values.
        @business.products.non_parent.ordered.includes(:brand).map do |product|
          on_hand = totals[product.id] || 0
          Row.new(
            product:     product,
            on_hand:     on_hand,
            last_cost:   product.last_purchase_price,
            unit_cost:   product.average_cost_price,
            stock_value: on_hand * product.average_cost_price
          )
        end
      end

      def total_value
        rows.sum(&:stock_value)
      end
    end
  end
end
