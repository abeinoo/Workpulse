module Inventory
  module Reports
    # "Most active products": products with the most consumption in a period.
    # Everything comes from Inventory::ConsumptionLedger (stock issues +
    # laundry consumption, net of voided issues), in three grouped queries.
    class ActiveProducts
      LIMIT = 10
      Row = Struct.new(:product, :quantity, :value, :issue_count, :top_branch, :top_branch_quantity, keyword_init: true)

      def initialize(business, period:, warehouse_ids: nil, limit: LIMIT)
        @business = business
        @limit    = limit
        @ledger   = ConsumptionLedger.new(business, reasons: ConsumptionLedger::ALL_CONSUMPTION,
                                                    warehouse_ids: warehouse_ids, from: period.from, to: period.to)
      end

      def rows
        @rows ||= begin
          totals = @ledger.totals_by("inventory_movements.product_id")
                          .select { |_, t| t[:quantity].positive? }
                          .sort_by { |_, t| -t[:quantity] }.first(@limit).to_h
          ids = totals.keys
          issues = @ledger.relation.where(direction: "out", product_id: ids)
                          .where(consumption_issues: { voided_at: nil })
                          .group("inventory_movements.product_id").count
          by_branch = @ledger.totals_by("inventory_movements.product_id", Arel.sql(ConsumptionLedger::BRANCH_SQL))
          top = by_branch.select { |(pid, bid), t| ids.include?(pid) && bid && t[:quantity].positive? }
                         .group_by { |(pid, _), _| pid }
                         .transform_values { |pairs| pairs.max_by { |_, t| t[:quantity] } }
          products = Product.where(id: ids).index_by(&:id)
          branches = @business.branches.where(id: top.values.map { |((_, bid), _)| bid }).index_by(&:id)

          totals.map do |pid, t|
            (_, bid), bt = top[pid]
            Row.new(product: products[pid], quantity: t[:quantity], value: t[:cost],
                    issue_count: issues[pid] || 0, top_branch: branches[bid], top_branch_quantity: bt&.dig(:quantity))
          end
        end
      end
    end
  end
end
