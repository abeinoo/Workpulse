class Inventory::DashboardController < Inventory::BaseController
  def index
    business = current_user.business
    wh_ids   = accessible_warehouse_ids   # nil = all warehouses

    @warehouse_count = accessible_warehouses.count
    # Exclude parent products — they carry no inventory; count only transactable ones.
    @product_count   = business.products.active.inventory_tracked.non_parent.count
    @supplier_count  = business.suppliers.count

    @totals = Inventory::StockLevels.totals_for(business, warehouse_ids: wh_ids)
    @low_stock_alerts = Inventory::LowStockQuery.new(business, warehouse_ids: wh_ids).alerts
    @suppliers = business.suppliers.ordered

    # Stock value: only non-parent tracked products (parents have no movements).
    tracked_products = business.products.active.inventory_tracked.non_parent
    @stock_value = tracked_products.sum { |p| (@totals[p.id] || 0) * p.average_cost_price }

    # Family low-stock: group child-product alerts by their parent so the dashboard
    # can surface "Hair Color — 2 children low in stock" summaries.
    @family_low_stock = @low_stock_alerts
      .select { |a| a.product.parent_product_id? }
      .group_by { |a| a.product.parent_product }
    # { parent_product => [alert, ...] }

    # Recent activity is warehouse-scoped through the policies.
    @recent_receipts = policy_scope(GoodsReceipt).recent.includes(:supplier, :warehouse).limit(5)
    @recent_issues   = policy_scope(StockIssue).recent.includes(:warehouse).limit(5)
  end
end
