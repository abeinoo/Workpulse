module Inventory
  module Reports
    # Adjustment / stocktake report: one row per posted adjustment movement,
    # with the quantity before and after it. Previous / new quantities are the
    # ledger running balance around that movement (Reports::Movements), so they
    # always agree with the movement report and with actual stock. Stock-count
    # approvals appear here too — they post through a stock_count adjustment.
    #
    # Voided adjustments still show (with their reversal row) so the audit
    # trail stays complete; the reversal row is labelled as such.
    class Adjustments
      Row = Struct.new(:movement_row, :adjustment, keyword_init: true) do
        delegate :product, :warehouse, :balance_before, :balance_after, :signed_quantity, :movement, to: :movement_row
        def reversal? = movement.reversal?
      end

      def initialize(business, warehouse_ids: nil, product_id: nil, from: nil, to: nil, reason: nil)
        @business      = business
        @warehouse_ids = warehouse_ids
        @product_id    = product_id
        @from          = from
        @to            = to
        @reason        = reason.presence_in(StockAdjustment::REASONS)
      end

      def rows
        @rows ||= begin
          movement_rows = Movements.new(@business, warehouse_ids: @warehouse_ids, product_id: @product_id,
                                        from: @from, to: @to, source_type: "StockAdjustment").rows
          # The movement rows already preloaded each source adjustment; just
          # add their creators in one query.
          adjustments = movement_rows.map(&:source).uniq
          ActiveRecord::Associations::Preloader.new(records: adjustments, associations: :created_by).call
          movement_rows.filter_map do |movement_row|
            adjustment = movement_row.source
            next if @reason && adjustment.reason != @reason

            Row.new(movement_row: movement_row, adjustment: adjustment)
          end
        end
      end

      def net_quantity = rows.sum(&:signed_quantity)
    end
  end
end
