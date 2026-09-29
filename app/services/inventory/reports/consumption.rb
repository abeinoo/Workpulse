module Inventory
  module Reports
    # Consumption report: stock consumed per product and branch in a period —
    # stock-issue and laundry-consumption OUT movements, net of voided-issue
    # reversals. All figures come from Inventory::ConsumptionLedger, the same
    # definition Finance's branch profitability uses, aggregated in SQL. Each
    # branch row also names its supplying warehouse (BranchSupplyMap: explicit
    # link, else inferred) for context — it does not change the quantities.
    class Consumption
      Row = Struct.new(:product, :branch, :issued_quantity, :reversed_quantity,
                       :net_quantity, :net_value, :supply_warehouses, :supply_source, keyword_init: true)

      def initialize(business, warehouse_ids: nil, branch_id: nil, product_id: nil, from: nil, to: nil)
        @supply_map = BranchSupplyMap.new(business, warehouse_ids: warehouse_ids)
        @ledger = ConsumptionLedger.new(business,
                                        reasons:       ConsumptionLedger::ALL_CONSUMPTION,
                                        warehouse_ids: warehouse_ids,
                                        product_id:    product_id,
                                        branch_id:     branch_id.presence&.to_i,
                                        from:          Movements.parse_date(from),
                                        to:            Movements.parse_date(to))
        @business = business
      end

      def rows
        @rows ||= begin
          totals   = @ledger.totals_by_branch_product
          products = Product.where(id: totals.keys.map(&:last)).index_by(&:id)
          branches = @business.branches.where(id: totals.keys.map(&:first).compact).index_by(&:id)
          warehouses = @business.warehouses.index_by(&:id)
          totals.map do |(branch_id, product_id), t|
            links = @supply_map.links_for_branch(branch_id)
            Row.new(product: products[product_id], branch: branches[branch_id],
                    issued_quantity: t[:issued], reversed_quantity: t[:reversed],
                    net_quantity: t[:quantity], net_value: t[:cost],
                    supply_warehouses: links.map { |l| warehouses[l.warehouse_id] }.compact.uniq,
                    supply_source: links.first&.source)
          end.sort_by { |row| [ -row.net_value, row.product.name ] }
        end
      end

      def total_value    = rows.sum(&:net_value)
      def total_quantity = rows.sum(&:net_quantity)
    end
  end
end
