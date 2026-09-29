module Inventory
  module Reports
    # Inactive / No-Movement report: tracked products with no ledger movement
    # in the last `days` days (in the selected warehouses) — slow or dead
    # stock. Products that never moved at all are included too. Last-movement
    # dates and on-hand both come straight from the movement ledger.
    class NoMovement
      DEFAULT_DAYS = 90
      DAY_OPTIONS  = [ 30, 60, 90, 180, 365 ].freeze

      Row = Struct.new(:product, :on_hand, :stock_value, :last_movement_on, :days_idle, keyword_init: true)

      attr_reader :days, :cutoff

      def initialize(business, warehouse_ids: nil, days: nil, today: nil)
        @business      = business
        @warehouse_ids = warehouse_ids
        @days          = days.to_i.positive? ? days.to_i : DEFAULT_DAYS
        @today         = today || BusinessDay.current(context: business)
        @cutoff        = @today - @days
      end

      def rows
        @rows ||= begin
          totals = StockLevels.totals_for(@business, warehouse_ids: @warehouse_ids)
          last   = last_movement_dates
          @business.products.active.inventory_tracked.non_parent.ordered.filter_map do |product|
            last_on = last[product.id]
            next if last_on && last_on > @cutoff

            on_hand = totals[product.id] || 0
            Row.new(product: product, on_hand: on_hand,
                    stock_value: on_hand * product.average_cost_price,
                    last_movement_on: last_on,
                    days_idle: last_on && (@today - last_on).to_i)
          end.sort_by { |row| [ row.last_movement_on || Date.new(0), row.product.name ] }
        end
      end

      def total_value
        rows.sum(&:stock_value)
      end

      private

      def last_movement_dates
        rel = InventoryMovement.for_business(@business)
        rel = rel.where(warehouse_id: @warehouse_ids) if @warehouse_ids
        rel.group(:product_id).maximum(:occurred_on)
      end
    end
  end
end
