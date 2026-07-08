class Inventory::StockIssueImportRowsController < Inventory::BaseController
  def resolve
    @batch = find_batch
    result = Inventory::Imports::StockIssueImportRowResolver.new(
      current_user.business, params[:id],
      product_id: row_params[:product_id].presence,
      sku:        row_params[:sku].presence,
      quantity:   row_params[:quantity].presence
    ).call
    @row = result.row
    render_row_update
  end

  def skip
    @batch = find_batch
    result = Inventory::Imports::StockIssueImportRowResolver.new(
      current_user.business, params[:id], skip: true
    ).call
    @row = result.row
    render_row_update
  end

  private

  def render_row_update
    @batch.reload
    respond_to do |format|
      format.turbo_stream
      format.html { redirect_to inventory_stock_issue_import_batch_path(@batch) }
    end
  end

  def row_params
    params.permit(:product_id, :sku, :quantity)
  end

  def find_batch
    authorize StockIssue, :create?
    batch = current_user.business.stock_issue_import_batches.find(params[:stock_issue_import_batch_id])
    ensure_warehouses_accessible!(batch.warehouse_id)
    batch
  end
end
