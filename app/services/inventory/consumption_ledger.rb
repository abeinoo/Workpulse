module Inventory
  # The single definition of "stock consumed" — shared by Finance (branch
  # profitability / expense details), the product page and the inventory
  # Consumption / Branch Comparison reports, so they can never disagree.
  #
  # Consumption = consumption OUT movements (stock_issue, and optionally
  # laundry_consumption) NET of the reversal IN movements posted when a stock
  # issue is voided. Quantities and costs are signed (OUT +, reversal −), so a
  # voided issue nets to zero over any window that contains both its posting
  # and its void. The reversal lands on its own occurred_on (the void's
  # business day) — history is never rewritten, a void in a later period is a
  # credit in that period (append-only correction, same as the ledger).
  #
  # Branch attribution: OUT stock-issue rows carry branch_id; reversal rows do
  # not (DocumentVoider copies product/warehouse/qty/cost only), so the branch
  # is taken from the voided issue itself; laundry consumption falls back to
  # the batch's laundry branch. All in SQL — no per-row lookups.
  class ConsumptionLedger
    ISSUE_JOIN   = "LEFT JOIN stock_issues consumption_issues " \
                   "ON inventory_movements.source_type = 'StockIssue' " \
                   "AND consumption_issues.id = inventory_movements.source_id".freeze
    LAUNDRY_JOIN = "LEFT JOIN laundry_batches consumption_batches " \
                   "ON inventory_movements.source_type = 'LaundryBatch' " \
                   "AND consumption_batches.id = inventory_movements.source_id".freeze

    BRANCH_SQL = "COALESCE(inventory_movements.branch_id, consumption_issues.branch_id, " \
                 "consumption_batches.laundry_branch_id)".freeze
    SIGNED_QTY  = "CASE WHEN inventory_movements.direction = 'out' " \
                  "THEN inventory_movements.quantity ELSE -inventory_movements.quantity END".freeze
    SIGNED_COST = "(#{SIGNED_QTY}) * inventory_movements.unit_cost".freeze
    ISSUED_QTY   = "SUM(CASE WHEN inventory_movements.direction = 'out' THEN inventory_movements.quantity ELSE 0 END)".freeze
    REVERSED_QTY = "SUM(CASE WHEN inventory_movements.direction = 'in' THEN inventory_movements.quantity ELSE 0 END)".freeze

    STOCK_ISSUE_ONLY   = %w[stock_issue].freeze
    ALL_CONSUMPTION    = %w[stock_issue laundry_consumption].freeze
    # Only stock issues can be voided into a consumption reversal.
    REVERSIBLE_SOURCES = %w[StockIssue].freeze

    def initialize(business, from: nil, to: nil, reasons: STOCK_ISSUE_ONLY,
                   warehouse_ids: nil, product_id: nil, branch_id: nil)
      @business      = business
      @from          = from
      @to            = to
      @reasons       = reasons
      @warehouse_ids = warehouse_ids
      @product_id    = product_id
      @branch_id     = branch_id.presence
    end

    # Consumption + reversal movements, with the attribution joins applied.
    def relation
      base = InventoryMovement.where(business_id: @business.id).joins(ISSUE_JOIN).joins(LAUNDRY_JOIN)
      base = base.where(warehouse_id: @warehouse_ids)        if @warehouse_ids
      base = base.where(product_id: @product_id)              if @product_id.present?
      base = base.where(inventory_movements: { occurred_on: @from.. }) if @from
      base = base.where(inventory_movements: { occurred_on: ..@to })   if @to
      base = base.where("#{BRANCH_SQL} = ?", @branch_id)      if @branch_id

      base.where(direction: "out", reason: @reasons)
          .or(base.where(direction: "in", reason: "reversal", source_type: REVERSIBLE_SOURCES))
    end

    # { branch_id => net consumption cost }
    def cost_by_branch
      relation.group(Arel.sql(BRANCH_SQL)).sum(Arel.sql(SIGNED_COST))
    end

    # { warehouse_id => net consumed quantity }
    def quantity_by_warehouse
      relation.group(:warehouse_id).sum(Arel.sql(SIGNED_QTY))
    end

    # { [branch_id, product_id] => { issued:, reversed:, quantity:, cost: } }
    def totals_by_branch_product
      totals_by(Arel.sql(BRANCH_SQL), "inventory_movements.product_id")
    end

    # { [branch_id, warehouse_id] => { issued:, reversed:, quantity:, cost: } }
    def totals_by_branch_warehouse
      totals_by(Arel.sql(BRANCH_SQL), "inventory_movements.warehouse_id")
    end

    # [[branch_id, warehouse_id], ...] — every (branch, supplying warehouse)
    # pair the posted ledger records, i.e. the warehouse ↔ branch supply
    # relationship. There is no stored link between the two; this is derived
    # from where consumption was actually issued from. Ignores the date window.
    def supply_pairs
      without_window.relation.where(direction: "out")
                    .distinct.pluck(Arel.sql(BRANCH_SQL), "inventory_movements.warehouse_id")
                    .reject { |branch_id, _| branch_id.nil? }
    end

    # { [branch_id, …] => latest occurred_on } of consumption still in force.
    def last_consumed_by(*groups)
      relation.where(direction: "out").where(consumption_issues: { voided_at: nil })
              .group(*groups).maximum("inventory_movements.occurred_on")
    end

    def net_quantity = relation.sum(Arel.sql(SIGNED_QTY))
    def net_cost     = relation.sum(Arel.sql(SIGNED_COST))

    # Signed totals grouped by the given SQL expressions (1 or 2 keys).
    def totals_by(*groups)
      relation.group(*groups)
              .pluck(*groups, Arel.sql(ISSUED_QTY), Arel.sql(REVERSED_QTY),
                     Arel.sql("SUM(#{SIGNED_QTY})"), Arel.sql("SUM(#{SIGNED_COST})"))
              .to_h do |row|
                keys = row.first(groups.size)
                issued, reversed, quantity, cost = row.last(4)
                [ keys.size == 1 ? keys.first : keys,
                  { issued: issued, reversed: reversed, quantity: quantity, cost: cost } ]
              end
    end

    # Same filters minus the date window (relationship queries).
    def without_window
      self.class.new(@business, reasons: @reasons, warehouse_ids: @warehouse_ids,
                                product_id: @product_id, branch_id: @branch_id)
    end

    # Latest day stock was consumed by an issue that is still in force.
    def last_consumed_on
      relation.where(direction: "out").where(consumption_issues: { voided_at: nil })
              .maximum("inventory_movements.occurred_on")
    end
  end
end
