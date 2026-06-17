class Inventory::DashboardController < Inventory::BaseController
  def index
    business = current_user.business
    wh_ids   = accessible_warehouse_ids   # nil = all warehouses

    @warehouse_count = accessible_warehouses.count
    @product_count   = business.products.inventory_tracked.count
    @supplier_count  = business.suppliers.count

    @totals = Inventory::StockLevels.totals_for(business, warehouse_ids: wh_ids)
    @low_stock_alerts = Inventory::LowStockQuery.new(business, warehouse_ids: wh_ids).alerts

    tracked_products = business.products.inventory_tracked
    @stock_value = tracked_products.sum { |p| (@totals[p.id] || 0) * p.average_cost_price }

    # Recent activity is warehouse-scoped through the policies.
    @recent_receipts = policy_scope(GoodsReceipt).recent.includes(:supplier, :warehouse).limit(5)
    @recent_issues   = policy_scope(StockIssue).recent.includes(:warehouse).limit(5)
  end
end
