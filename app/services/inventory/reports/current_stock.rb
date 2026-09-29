module Inventory
  module Reports
    # Current Stock report: on-hand, last cost and stock value per product,
    # restricted to a set of warehouses (nil = all). On-hand comes from the
    # movement ledger via StockLevels.totals_for — the same figure every other
    # inventory screen shows.
    #
    # stock_status narrows the list: "out_of_stock" (on-hand <= 0) or
    # "in_stock" (on-hand > 0); nil = every product.
    class CurrentStock
      STOCK_STATUSES = %w[in_stock out_of_stock].freeze

      Row = Struct.new(:product, :on_hand, :last_cost, :unit_cost, :stock_value, keyword_init: true) do
        def out_of_stock? = on_hand <= 0
      end

      def initialize(business, warehouse_ids: nil, stock_status: nil)
        @business      = business
        @warehouse_ids = warehouse_ids
        @stock_status  = stock_status.presence_in(STOCK_STATUSES)
      end

      def rows
        @rows ||= all_rows.select { |row| matches_status?(row) }
      end

      def total_value
        rows.sum(&:stock_value)
      end

      def out_of_stock_count
        all_rows.count(&:out_of_stock?)
      end

      private

      # Untracked products have no stock to report; parents carry no inventory
      # of their own — their children appear as their own rows.
      def all_rows
        @all_rows ||= begin
          totals = StockLevels.totals_for(@business, warehouse_ids: @warehouse_ids)
          @business.products.active.inventory_tracked.non_parent.ordered.includes(:brand).map do |product|
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
      end

      def matches_status?(row)
        case @stock_status
        when "out_of_stock" then row.out_of_stock?
        when "in_stock"     then !row.out_of_stock?
        else true
        end
      end
    end
  end
end
