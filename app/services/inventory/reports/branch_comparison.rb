module Inventory
  module Reports
    # Branch comparison for ONE product — reporting layer only; it reads the
    # posted movement ledger and never changes stock ownership.
    #
    # Stock is owned by WAREHOUSES; branches consume it through stock issues
    # (and laundry batches). Which warehouse supplies which branch comes from
    # Inventory::BranchSupplyMap: the explicit WarehouseBranchSupply link when
    # an admin has set one, else the ledger-inferred link (fallback).
    #
    #   BranchRow    — one per branch: its supplying warehouse(s) and link
    #                  source, and its consumption (ConsumptionLedger — issues
    #                  net of voided-issue reversals, reversal on the original
    #                  branch). Warehouse stock and coverage are shown on the
    #                  branch row ONLY when the branch has exactly one supplying
    #                  warehouse that supplies no other branch; shared stock is
    #                  never repeated per branch (it would imply N× the units).
    #   WarehouseRow — one per warehouse, stock shown ONCE: opening balance +
    #                  receipts + transfers in + adjustments in − consumption
    #                  − transfers out − adjustments out ± reversals = closing,
    #                  all SQL-aggregated from the ledger; closing is checked
    #                  against StockLevels (the Current Stock figure).
    class BranchComparison
      DEFAULT_PERIOD_DAYS = 30
      SIGNED = "CASE WHEN inventory_movements.direction = 'in' " \
               "THEN inventory_movements.quantity ELSE -inventory_movements.quantity END".freeze

      BranchRow = Struct.new(:branch, :warehouses, :source, :shared, :warehouse_stock, :issued, :reversed,
                             :net_consumption, :consumption_value, :share, :avg_daily_consumption,
                             :coverage_days, :last_consumed_on, keyword_init: true) do
        def shared? = shared
        def consuming? = net_consumption.positive?
        def warehouse = warehouses.first
        # Exactly one supplying warehouse that supplies only this branch.
        def exclusive? = warehouses.size == 1 && !shared
      end

      WarehouseRow = Struct.new(:warehouse, :branches, :opening, :receipts, :transfers_in, :transfers_out,
                                :adjustments_in, :adjustments_out, :consumption, :reversals, :closing,
                                :current_stock, :unit_cost, :stock_value, :avg_daily_consumption,
                                :coverage_days, :last_movement_on, keyword_init: true) do
        def shared? = branches.size > 1
        # Only meaningful when the period ends today or later.
        def reconciles? = closing == current_stock
      end

      attr_reader :product, :from, :to

      def initialize(business, product_id:, warehouse_ids: nil, branch_id: nil, from: nil, to: nil, today: nil)
        @business      = business
        @warehouse_ids = warehouse_ids
        @branch_id     = branch_id.presence&.to_i
        @today         = today || BusinessDay.current(context: business)
        @to            = Movements.parse_date(to) || @today
        @from          = Movements.parse_date(from) || (@to - (DEFAULT_PERIOD_DAYS - 1))
        @product       = product_id.present? ? business.products.find_by(id: product_id) : nil
      end

      def ready?      = product.present?
      def period_days = [ (@to - @from).to_i + 1, 1 ].max
      def period_includes_today? = @to >= @today

      # ── Branches ──────────────────────────────────────────────────────────
      def branch_rows
        return [] unless ready?

        @branch_rows ||= begin
          totals = consumption_ledger.totals_by(Arel.sql(ConsumptionLedger::BRANCH_SQL))
          last   = consumption_ledger.last_consumed_by(Arel.sql(ConsumptionLedger::BRANCH_SQL))
          ids    = (supply_map.branch_ids + totals.keys.compact).uniq
          ids    = ids.select { |id| id == @branch_id } if @branch_id
          total  = ids.sum { |id| totals.dig(id, :quantity) || 0 }

          ids.filter_map do |branch_id|
            branch = branches[branch_id] or next
            links  = supply_map.links_for_branch(branch_id)
            whs    = links.map { |l| warehouses_by_id[l.warehouse_id] }.compact.uniq
            shared = whs.any? { |w| supply_map.shared_warehouse?(w.id) }
            t      = totals[branch_id] || { issued: 0, reversed: 0, quantity: 0, cost: 0 }
            daily  = t[:quantity] / period_days
            exclusive = whs.size == 1 && !shared
            stock  = exclusive ? (current_stock[whs.first.id] || 0) : nil

            BranchRow.new(
              branch: branch, warehouses: whs, source: links.first&.source, shared: shared,
              warehouse_stock: stock, issued: t[:issued], reversed: t[:reversed],
              net_consumption: t[:quantity], consumption_value: t[:cost],
              share: total.positive? ? t[:quantity] / total * 100 : 0,
              avg_daily_consumption: daily,
              coverage_days: (exclusive && daily.positive?) ? stock / daily : nil,
              last_consumed_on: last[branch_id]
            )
          end.sort_by { |row| [ -row.net_consumption, row.branch.name ] }
        end
      end

      # ── Warehouses (stock shown once) ─────────────────────────────────────
      def warehouse_rows
        return [] unless ready?

        @warehouse_rows ||= begin
          opening = scoped_movements.where("inventory_movements.occurred_on < ?", @from)
                                    .group(:warehouse_id).sum(Arel.sql(SIGNED))
          flows   = period_flows
          last    = scoped_movements.group(:warehouse_id).maximum(:occurred_on)
          unit    = product.average_cost_price
          ids     = (opening.keys + flows.keys.map(&:first) + current_stock.keys +
                     supply_map.links.map(&:warehouse_id)).uniq
          ids    &= @warehouse_ids if @warehouse_ids

          warehouses.select { |w| ids.include?(w.id) }.map do |warehouse|
            id = warehouse.id
            f  = ->(bucket) { flows[[ id, bucket ]] || 0 }
            closing = (opening[id] || 0) + f.(:receipts) + f.(:transfers_in) + f.(:adjustments_in) -
                      f.(:consumption) - f.(:transfers_out) - f.(:adjustments_out) + f.(:reversals)
            stock   = current_stock[id] || 0
            used    = f.(:consumption) - consumption_reversals_for(id)
            daily   = used / period_days
            WarehouseRow.new(
              warehouse: warehouse, branches: supply_map.branch_ids_for_warehouse(id).map { |bid| branches[bid] }.compact,
              opening: opening[id] || 0, receipts: f.(:receipts),
              transfers_in: f.(:transfers_in), transfers_out: f.(:transfers_out),
              adjustments_in: f.(:adjustments_in), adjustments_out: f.(:adjustments_out),
              consumption: f.(:consumption), reversals: f.(:reversals), closing: closing,
              current_stock: stock, unit_cost: unit, stock_value: stock * unit,
              avg_daily_consumption: daily, coverage_days: daily.positive? ? stock / daily : nil,
              last_movement_on: last[id]
            )
          end
        end
      end

      # ── Summary (factual, no ranking language) ────────────────────────────
      def total_stock       = warehouse_rows.sum(&:current_stock)
      def total_value       = warehouse_rows.sum(&:stock_value)
      def total_consumption = branch_rows.sum(&:net_consumption)
      def consuming_rows    = branch_rows.select(&:consuming?)
      def highest_branch    = consuming_rows.max_by(&:net_consumption)
      def lowest_branch     = consuming_rows.min_by(&:net_consumption)
      def consuming_branch_count = consuming_rows.map(&:branch).uniq.size

      # Branches offered in the branch filter: those supplied (explicitly or,
      # as a fallback, by inference) by the warehouses this user may see.
      def selectable_branches = supply_map.branches

      def supply_map
        @supply_map ||= BranchSupplyMap.new(@business, warehouse_ids: @warehouse_ids)
      end

      # Drill-down: the Stock Movement report's own query (same window
      # balances) narrowed to this product + branch + period.
      def movements_for(branch_id)
        Movements.new(@business, warehouse_ids: @warehouse_ids, product_id: product.id,
                                 branch_id: branch_id, from: @from, to: @to)
      end

      private

      def consumption_ledger
        @consumption_ledger ||= ConsumptionLedger.new(@business, reasons: ConsumptionLedger::ALL_CONSUMPTION,
                                                                 product_id: product.id, warehouse_ids: @warehouse_ids,
                                                                 from: @from, to: @to)
      end

      def branches
        @branches ||= @business.branches.where(id: supply_map.branch_ids +
                                                   consumption_ledger.totals_by(Arel.sql(ConsumptionLedger::BRANCH_SQL)).keys)
                                        .index_by(&:id)
      end

      def warehouses
        rel = @business.warehouses.ordered
        @warehouse_ids ? rel.where(id: @warehouse_ids) : rel
      end

      def warehouses_by_id = @warehouses_by_id ||= warehouses.index_by(&:id)

      # Warehouse stock from the ledger — the same StockLevels figure the
      # Current Stock report shows.
      def current_stock
        @current_stock ||= StockLevels.new(product).by_warehouse
      end

      def scoped_movements
        rel = InventoryMovement.where(business_id: @business.id, product_id: product.id)
        @warehouse_ids ? rel.where(warehouse_id: @warehouse_ids) : rel
      end

      # { [warehouse_id, bucket] => positive quantity in the period }. Reversals
      # are kept as their own signed bucket (the ± term of the reconciliation).
      def period_flows
        scoped_movements.where(occurred_on: @from..@to)
                        .group(:warehouse_id, :reason, :direction).sum(:quantity)
                        .each_with_object(Hash.new(0)) do |((warehouse_id, reason, direction), qty), acc|
          bucket = case reason
          when "goods_receipt" then :receipts
          when "transfer_in" then :transfers_in
          when "transfer_out" then :transfers_out
          when "adjustment", "opening_balance" then direction == "in" ? :adjustments_in : :adjustments_out
          when "stock_issue", "laundry_consumption" then :consumption
          when "reversal" then :reversals
          end
          next unless bucket

          acc[[ warehouse_id, bucket ]] += bucket == :reversals && direction == "out" ? -qty : qty
        end
      end

      # Consumption reversed (voided issues) per warehouse in the period — from
      # the same ConsumptionLedger, so warehouse net consumption = Σ branch rows.
      def consumption_reversals_for(warehouse_id)
        @consumption_reversals ||= consumption_ledger.totals_by("inventory_movements.warehouse_id")
        @consumption_reversals.dig(warehouse_id, :reversed) || 0
      end
    end
  end
end
