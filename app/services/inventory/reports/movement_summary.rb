module Inventory
  module Reports
    # Movement totals for a period, straight from the posted ledger in one
    # grouped SQL query (warehouse-scoped). Reversals (voids) are folded back
    # into the flow of the document they reverse, so a voided issue reduces
    # "issues" — exactly as Inventory::ConsumptionLedger nets it — and the
    # buckets always add up to the ledger's net movement:
    #
    #   net = receipts − issues + transfers_in − transfers_out + adjustments
    #
    # Each bucket carries quantity and value (quantity × unit_cost at posting).
    # Value is the comparable figure across products with different units.
    class MovementSummary
      BUCKETS = %i[receipts issues transfers_in transfers_out adjustments].freeze
      Totals  = Struct.new(:quantity, :value) do
        def self.zero = new(0, 0)
      end

      def initialize(business, period:, warehouse_ids: nil)
        @business      = business
        @period        = period
        @warehouse_ids = warehouse_ids
      end

      # { bucket => Totals } — positive magnitudes except :adjustments (signed).
      def totals
        @totals ||= grouped.each_with_object(BUCKETS.index_with { Totals.zero }) do |((_day, reason, source_type, direction), (qty, value)), acc|
          bucket, sign = self.class.bucket_for(reason, source_type, direction)
          next unless bucket

          acc[bucket].quantity += sign * qty
          acc[bucket].value    += sign * value
        end
      end

      def net
        t = totals
        Totals.new(
          t[:receipts].quantity - t[:issues].quantity + t[:transfers_in].quantity - t[:transfers_out].quantity + t[:adjustments].quantity,
          t[:receipts].value - t[:issues].value + t[:transfers_in].value - t[:transfers_out].value + t[:adjustments].value
        )
      end

      # Daily receipts / issues value for the trend chart: [[date, in, out], …]
      # for every day of the period (zero-filled).
      def daily_trend
        @daily_trend ||= begin
          by_day = Hash.new { |h, k| h[k] = { receipts: 0, issues: 0 } }
          grouped.each do |(day, reason, source_type, direction), (_qty, value)|
            bucket, sign = self.class.bucket_for(reason, source_type, direction)
            by_day[day][bucket] += sign * value if %i[receipts issues].include?(bucket)
          end
          @period.range.map { |day| [ day, by_day[day][:receipts], by_day[day][:issues] ] }
        end
      end

      def movement_count = counts_by_warehouse.values.sum

      # { warehouse_id => number of ledger movements in the period }
      def counts_by_warehouse
        @counts_by_warehouse ||= scope.group(:warehouse_id).count
      end

      # [bucket, sign] for a ledger row. sign turns the row into the bucket's
      # positive direction (e.g. an issue reversal is −1 on :issues).
      def self.bucket_for(reason, source_type, direction)
        inbound = direction == "in"
        case reason
        when "goods_receipt"                       then [ :receipts, 1 ]
        when "stock_issue", "laundry_consumption"  then [ :issues, 1 ]
        when "transfer_in"                         then [ :transfers_in, 1 ]
        when "transfer_out"                        then [ :transfers_out, 1 ]
        when "adjustment", "opening_balance"       then [ :adjustments, inbound ? 1 : -1 ]
        when "reversal"
          case source_type
          when "GoodsReceipt"    then [ :receipts, -1 ]
          when "StockIssue"      then [ :issues, -1 ]
          # A voided transfer: OUT of the destination undoes transfer-in,
          # IN to the source undoes transfer-out.
          when "StockTransfer"   then inbound ? [ :transfers_out, -1 ] : [ :transfers_in, -1 ]
          when "StockAdjustment" then [ :adjustments, inbound ? 1 : -1 ]
          end
        end
      end

      private

      def scope
        rel = InventoryMovement.where(business_id: @business.id, occurred_on: @period.range)
        @warehouse_ids ? rel.where(warehouse_id: @warehouse_ids) : rel
      end

      # { [day, reason, source_type, direction] => [quantity, value] }
      def grouped
        @grouped ||= scope.group(:occurred_on, :reason, :source_type, :direction)
                          .pluck(:occurred_on, :reason, :source_type, :direction,
                                 Arel.sql("SUM(quantity)"), Arel.sql("SUM(quantity * unit_cost)"))
                          .to_h { |d, r, s, dir, q, v| [ [ d, r, s, dir ], [ q, v ] ] }
      end
    end
  end
end
