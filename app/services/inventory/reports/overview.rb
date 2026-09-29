module Inventory
  module Reports
    # Headline figures for the Inventory Reports hub. Every number is taken
    # from the report service its card opens, so a card's metric always
    # matches the report behind it — no separate stock arithmetic here.
    class Overview
      attr_reader :today

      def initialize(business, warehouse_ids: nil)
        @business      = business
        @warehouse_ids = warehouse_ids
        @today         = BusinessDay.current(context: business)
      end

      def current_stock
        @current_stock ||= CurrentStock.new(@business, warehouse_ids: @warehouse_ids)
      end

      def total_value         = current_stock.total_value
      def product_count       = current_stock.rows.size
      def out_of_stock_count  = current_stock.out_of_stock_count
      def low_stock_count     = low_stock_alerts.size
      def no_movement_count   = NoMovement.new(@business, warehouse_ids: @warehouse_ids, today: @today).rows.size

      def low_stock_alerts
        @low_stock_alerts ||= LowStockQuery.new(@business, warehouse_ids: @warehouse_ids).alerts
      end

      def todays_movement_count
        rel = @business.inventory_movements.where(occurred_on: @today)
        rel = rel.where(warehouse_id: @warehouse_ids) if @warehouse_ids
        rel.count
      end

      def month_range = @today.beginning_of_month..@today

      def month_consumption_value
        ConsumptionLedger.new(@business, reasons: ConsumptionLedger::ALL_CONSUMPTION, warehouse_ids: @warehouse_ids,
                                         from: month_range.first, to: month_range.last).net_cost
      end

      def month_purchase_value
        purchases_this_month.summary[:total_value]
      end

      def outstanding_to_suppliers
        Purchases.new(@business, warehouse_ids: @warehouse_ids).summary[:outstanding]
      end

      private

      def purchases_this_month
        Purchases.new(@business, warehouse_ids: @warehouse_ids, from: month_range.first, to: month_range.last)
      end
    end
  end
end
