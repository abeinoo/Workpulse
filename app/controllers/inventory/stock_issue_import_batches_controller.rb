class Inventory::StockIssueImportBatchesController < Inventory::BaseController
  def show
    @batch = find_batch
    @rows  = load_rows(@batch)
  end

  def complete
    @batch = find_batch
    result = Inventory::Imports::StockIssueImportBatchCompleter.new(
      current_user.business, @batch.id, user: current_user
    ).call
    @batch = result.batch
    @rows  = load_rows(@batch)

    respond_to do |format|
      format.turbo_stream
      format.html do
        if result.ok? && @batch.stock_issue.issued?
          redirect_to inventory_stock_issue_path(@batch.stock_issue),
                      notice: t("inventory.imports.import_completed")
        elsif result.ok?
          redirect_to inventory_stock_issue_import_batch_path(@batch),
                      notice: t("inventory.imports.import_completed")
        else
          redirect_to inventory_stock_issue_import_batch_path(@batch),
                      alert: t("inventory.imports.complete_failed")
        end
      end
    end
  end

  private

  # Preloads everything the row cards' product-info panel needs (image,
  # barcodes) and shares this same `batch` instance with each row so
  # `row.batch.warehouse` doesn't refetch per card.
  def load_rows(batch)
    rows = batch.rows.ordered.includes(product: [ :product_barcodes, { image_attachment: :blob } ])
    rows.each { |row| row.association(:batch).target = batch }
    rows
  end

  def find_batch
    authorize StockIssue, :create?
    batch = current_user.business.stock_issue_import_batches.find(params[:id])
    ensure_warehouses_accessible!(batch.warehouse_id)
    batch
  end
end
