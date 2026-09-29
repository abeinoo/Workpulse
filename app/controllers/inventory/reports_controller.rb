# Inventory Reports hub + reports. Every report reads the posted movement
# ledger (InventoryMovement) or posted documents through the services in
# Inventory::Reports — no stock arithmetic here. All actions share one gate
# (require_reports_access!) and one warehouse scope (effective_warehouse_ids).
class Inventory::ReportsController < Inventory::BaseController
  # Filters shared by the movement screen, its pagination links and exports.
  CONSUMPTION_PERIODS = %w[today 7d month last_month 3m 6m year custom].freeze
  MOVEMENT_FILTERS = %i[warehouse_id product_id branch_id from to reason direction document_number].freeze

  before_action :require_reports_access!

  def index
    @overview = Inventory::Reports::Overview.new(current_user.business, warehouse_ids: accessible_warehouse_ids)
  end

  def current_stock
    @report = Inventory::Reports::CurrentStock.new(current_user.business,
                                                   warehouse_ids: effective_warehouse_ids,
                                                   stock_status:  params[:stock_status])
    @rows       = @report.rows
    @warehouses = accessible_warehouses
  end

  # Optional ?branch_id narrows to the warehouses that supply that branch
  # (explicit link, else inferred) — still within the user's warehouses.
  def low_stock
    @branches   = report_branches
    @branch     = @branches.find_by(id: params[:branch_id]) if params[:branch_id].present?
    @report     = Inventory::Reports::LowStock.new(current_user.business, warehouse_ids: low_stock_warehouse_ids)
    @rows       = @report.rows
    @warehouses = accessible_warehouses
    @suppliers  = current_user.business.suppliers.ordered
  end

  def no_movement
    @report     = Inventory::Reports::NoMovement.new(current_user.business,
                                                     warehouse_ids: effective_warehouse_ids, days: params[:days])
    @rows       = @report.rows
    @warehouses = accessible_warehouses
  end

  # One product across the branches it is consumed in (consumption, from
  # ConsumptionLedger) and the warehouses that supply them (stock, shown once
  # per warehouse). Scoped users only see their warehouses and the branches
  # those warehouses supply. The drill-down reuses the Stock Movement query.
  def branch_comparison
    @report     = branch_comparison_report
    # Show the effective period (default: last 30 days) in the date inputs,
    # and carry it into export / drill-down links.
    params[:from] = @report.from.iso8601 if params[:from].blank?
    params[:to]   = @report.to.iso8601   if params[:to].blank?
    @warehouses = accessible_warehouses
    @branches   = @report.selectable_branches
    @products   = current_user.business.products.active.inventory_tracked.non_parent.ordered
    return unless @report.ready? && params[:drill_branch_id].present?

    @drill_branch  = @branches.find_by(id: params[:drill_branch_id])
    return unless @drill_branch

    drill          = @report.movements_for(@drill_branch.id)
    @drill_total   = drill.total_count
    @drill_pages   = drill.total_pages(25)
    @drill_page    = params[:drill_page].to_i.clamp(1, @drill_pages)
    @drill_rows    = drill.page(@drill_page, 25)
  end

  def export_branch_comparison
    report = branch_comparison_report
    return redirect_to(inventory_branch_comparison_report_path(request.query_parameters.except("file"))) unless report.ready?

    export = Inventory::Reports::BranchComparisonExport.new(report)
    if params[:file] == "xlsx"
      send_data export.to_xlsx, filename: export.filename("xlsx"), type: Inventory::Reports::BranchComparisonExport::XLSX_TYPE
    else
      send_data export.to_csv, filename: export.filename("csv"), type: "text/csv; charset=utf-8"
    end
  end

  # Paginated in SQL — only the requested page is loaded; balances come from
  # the full-history window in Reports::Movements, so paging never changes them.
  def movements
    @report      = movements_report
    @per_page    = Inventory::Reports::Movements.per_page_for(params[:per_page])
    @total_count = @report.total_count
    @total_pages = @report.total_pages(@per_page)
    @page        = params[:page].to_i.clamp(1, @total_pages)
    @rows        = @report.page(@page, @per_page)
    @warehouses  = accessible_warehouses
    @products    = current_user.business.products.ordered
    @branches    = report_branches
  end

  # Same report object (same filters, query and balances) as the screen,
  # streamed in batches.
  def export_movements
    export = Inventory::Reports::MovementsExport.new(movements_report, business: current_user.business)
    if params[:file] == "xlsx"
      send_data export.to_xlsx, filename: export.filename("xlsx"), type: Inventory::Reports::MovementsExport::XLSX_TYPE
    else
      send_data export.to_csv, filename: export.filename("csv"), type: "text/csv; charset=utf-8"
    end
  end

  # Auto-applying filters: period preset (default this month) or a custom
  # from/to, branch and product. Old links carrying only from/to still work
  # (treated as a custom period). A branch outside the user's list is ignored.
  def consumption
    @branches   = report_branches
    @warehouses = accessible_warehouses
    @products   = current_user.business.products.ordered
    period_key  = params[:period].presence || (params[:from].present? || params[:to].present? ? "custom" : nil)
    @period     = Inventory::Reports::Period.new(current_user.business, key: period_key, from: params[:from], to: params[:to],
                                                                        default: "month", keys: CONSUMPTION_PERIODS)
    @selected_branch_id = @branches.find_by(id: params[:branch_id])&.id
    @report = Inventory::Reports::Consumption.new(
      current_user.business,
      warehouse_ids: effective_warehouse_ids,
      branch_id:     @selected_branch_id,
      product_id:    params[:product_id],
      from:          @period.from,
      to:            @period.to
    )
    @rows = @report.rows
  end

  def transfers
    @report = Inventory::Reports::Transfers.new(
      current_user.business,
      warehouse_ids: effective_warehouse_ids,
      product_id:    params[:product_id],
      from:          params[:from],
      to:            params[:to],
      status:        params[:status]
    )
    @rows       = @report.rows
    @warehouses = accessible_warehouses
    @products   = current_user.business.products.ordered
  end

  def adjustments
    @report = Inventory::Reports::Adjustments.new(
      current_user.business,
      warehouse_ids: effective_warehouse_ids,
      product_id:    params[:product_id],
      from:          params[:from],
      to:            params[:to],
      reason:        params[:reason]
    )
    @rows       = @report.rows
    @warehouses = accessible_warehouses
    @products   = current_user.business.products.ordered
  end

  def purchases
    @report = Inventory::Reports::Purchases.new(
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

  def movements_report
    Inventory::Reports::Movements.new(
      current_user.business,
      warehouse_ids:   effective_warehouse_ids,
      product_id:      params[:product_id],
      from:            params[:from],
      to:              params[:to],
      reason:          params[:reason],
      direction:       params[:direction],
      document_number: params[:document_number],
      branch_id:       params[:branch_id]
    )
  end

  # Branches offered in branch filters: those supplied by the warehouses the
  # user can access — explicit supply links first, ledger-inferred as fallback
  # (Inventory::BranchSupplyMap). A warehouse-scoped user never sees others.
  def report_branches
    supply_map.branches
  end

  def supply_map
    @supply_map ||= Inventory::BranchSupplyMap.new(current_user.business, warehouse_ids: accessible_warehouse_ids)
  end

  def low_stock_warehouse_ids
    ids = effective_warehouse_ids
    return ids unless @branch

    supplying = supply_map.warehouse_ids_for(@branch.id)
    ids ? (ids & supplying) : supplying
  end

  def branch_comparison_report
    Inventory::Reports::BranchComparison.new(
      current_user.business,
      product_id:    params[:product_id],
      warehouse_ids: effective_warehouse_ids,
      branch_id:     params[:branch_id],
      from:          params[:from],
      to:            params[:to]
    )
  end

  def comparison_filter_params
    params.permit(:product_id, :warehouse_id, :branch_id, :from, :to).to_h.compact_blank
  end
  helper_method :comparison_filter_params

  def movement_filter_params
    params.permit(*MOVEMENT_FILTERS).to_h.compact_blank
  end
  helper_method :movement_filter_params

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
