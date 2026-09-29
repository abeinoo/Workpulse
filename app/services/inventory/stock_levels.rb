module Inventory
  # Derives on-hand stock for a product from the immutable movement ledger.
  # Stock is never stored on the product — it is always SUM(in) - SUM(out).
  class StockLevels
    # Signed quantity of one movement (+in / −out) and its sum — the one
    # definition of on-hand stock.
    SIGNED     = "CASE WHEN direction = 'in' THEN quantity ELSE -quantity END".freeze
    SIGNED_SUM = "COALESCE(SUM(#{SIGNED}), 0)".freeze

    def initialize(product)
      @product = product
    end

    # Total on-hand across every warehouse.
    def total
      @product.inventory_movements.pick(Arel.sql(SIGNED_SUM)) || 0
    end

    # On-hand in a single warehouse (accepts a Warehouse or its id).
    def in_warehouse(warehouse)
      warehouse_id = warehouse.respond_to?(:id) ? warehouse.id : warehouse
      @product.inventory_movements
              .where(warehouse_id: warehouse_id)
              .pick(Arel.sql(SIGNED_SUM)) || 0
    end

    # { warehouse_id => on_hand } for every warehouse this product has moved through.
    def by_warehouse
      @product.inventory_movements
              .group(:warehouse_id)
              .sum(Arel.sql(SIGNED))
    end

    # Class helper: on-hand for many products at once.
    # Returns { product_id => on_hand }. Avoids N+1 on index/report pages.
    # Pass warehouse_ids to restrict to a subset (e.g. a warehouse-scoped user);
    # nil means all warehouses.
    def self.totals_for(business, warehouse_ids: nil)
      relation = InventoryMovement.for_business(business)
      relation = relation.where(warehouse_id: warehouse_ids) if warehouse_ids
      relation.group(:product_id)
              .sum(Arel.sql(SIGNED))
    end

    # Family stock for a parent product: single query summing movements across
    # all child products. Fully warehouse-scoped when warehouse_ids is provided.
    def self.family_total(parent_product, warehouse_ids: nil)
      child_ids = parent_product.child_products.loaded? ?
                    parent_product.child_products.map(&:id) :
                    parent_product.child_products.pluck(:id)
      return 0 if child_ids.empty?
      relation = InventoryMovement.where(product_id: child_ids)
      relation = relation.where(warehouse_id: warehouse_ids) if warehouse_ids
      relation.pick(Arel.sql(SIGNED_SUM)) || 0
    end
  end
end
