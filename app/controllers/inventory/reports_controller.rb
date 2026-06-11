class Inventory::ReportsController < Inventory::BaseController
  before_action :require_reports_access!

  def index
    @warehouses = accessible_warehouses
  end

  def current_stock
    @report = Inventory::Reports::CurrentStock.new(current_user.business, warehouse_ids: effective_warehouse_ids)
    @rows   = @report.rows
    @warehouses = accessible_warehouses
  end

  def movements
    @report = Inventory::Reports::Movements.new(
      current_user.business,
      warehouse_ids: effective_warehouse_ids,
      product_id:    params[:product_id],
      from:          params[:from],
      to:            params[:to]
    )
    @rows       = @report.rows
    @warehouses = accessible_warehouses
    @products   = current_user.business.products.ordered
  end

  def supplier_purchases
    @report = Inventory::Reports::SupplierPurchases.new(
      current_user.business,
      warehouse_ids: effective_warehouse_ids,
      supplier_id:   params[:supplier_id],
      from:          params[:from],
      to:            params[:to]
    )
    @rows       = @report.rows
    @warehouses = accessible_warehouses
    @suppliers  = current_user.business.suppliers.ordered
  end

  private

  def require_reports_access!
    return if current_user.can?(:view_inventory_reports) ||
              current_user.can?(:view_inventory) ||
              current_user.can?(:manage_inventory)

    redirect_to root_path, alert: t("flash.not_authorized")
  end

  # The accessible warehouses narrowed by an optional ?warehouse_id filter.
  # nil means "all accessible warehouses"; an empty array means the filter chose
  # a warehouse the user can't see (so they get no data).
  def effective_warehouse_ids
    allowed  = accessible_warehouse_ids   # nil = all
    selected = params[:warehouse_id].presence
    return allowed unless selected

    chosen = [ selected.to_i ]
    allowed ? (chosen & allowed) : chosen
  end
end
