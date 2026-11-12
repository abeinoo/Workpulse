class Inventory::StockCountsController < Inventory::BaseController
  def index
    authorize StockCount
    @stock_counts = policy_scope(StockCount).recent.includes(:warehouse, :created_by, :approved_by)
    @stock_counts = @stock_counts.where(warehouse_id: params[:warehouse_id]) if params[:warehouse_id].present?
    @stock_counts = @stock_counts.where(status: params[:status])             if params[:status].present?
    @warehouses   = accessible_warehouses
  end

  def show
    @stock_count = find_count
    authorize @stock_count
    # Load the items association itself (with products) so the summary
    # figures (StockCount#adjustment_value etc., which read `items`) and the
    # worksheet rows share one load, instead of the summaries re-loading items
    # and each product one by one. Barcodes come from one bulk lookup (same
    # primary/first rule as Product#barcode).
    ActiveRecord::Associations::Preloader.new(
      records: [ @stock_count ],
      associations: [ { items: :product }, { stock_adjustments: [ :created_by, :voided_by ] }, :cancelled_by ]
    ).call
    @items             = @stock_count.items
    @product_barcodes  = Product.barcode_lookup(@items.map(&:product_id))
    @legacy_count      = @items.count(&:legacy_unverified?)
    @adjustments       = @stock_count.stock_adjustments.sort_by(&:id)
    @active_adjustment = @stock_count.active_stock_adjustment
    @history           = AuditLog.for_auditable(@stock_count).includes(:actor).order(:created_at, :id).last(100)
  end

  def new
    @stock_count = current_user.business.stock_counts.build(counted_on: Date.current)
    authorize @stock_count
    @warehouses = accessible_warehouses
  end

  # Creating a session preloads a count row for every product in the business.
  def create
    authorize StockCount
    ensure_warehouses_accessible!(session_params[:warehouse_id])
    result = Inventory::StockCountCreator.new(actor: current_user, **session_params.to_h.symbolize_keys).call

    if result.ok?
      redirect_to edit_inventory_stock_count_path(result.count), notice: t("inventory.stock_counts.created")
    else
      @stock_count = result.count
      @warehouses  = accessible_warehouses
      render :new, status: :unprocessable_entity
    end
  end

  # The counting screen. Rows not yet physically counted show the warehouse's
  # live on-hand (the baseline their count will be compared to).
  def edit
    @stock_count = find_count
    authorize @stock_count
    load_counting_screen
  end

  # Saving counted quantities; the first save moves draft → in_progress.
  def update
    @stock_count = find_count
    authorize @stock_count
    result = Inventory::StockCountRecorder.new(
      stock_count_id: @stock_count.id, actor: current_user,
      entries: count_entries, notes: params.dig(:stock_count, :notes)
    ).call

    if result.ok?
      redirect_to inventory_stock_count_path(@stock_count), notice: t("inventory.stock_counts.updated")
    else
      flash.now[:alert] = result.error
      load_counting_screen
      render :edit, status: :unprocessable_entity
    end
  end

  # Hard delete — only a never-posted count still being worked on.
  def destroy
    @stock_count = find_count
    authorize @stock_count
    result = Inventory::StockCountRemoval.new(stock_count_id: @stock_count.id, actor: current_user,
                                              reason: params[:reason]).delete!
    if result.ok?
      redirect_to inventory_stock_counts_path, notice: t("inventory.stock_counts.deleted")
    else
      redirect_to inventory_stock_count_path(@stock_count), alert: result.error
    end
  end

  # Cancel — a reopened count that once posted stock (never hard-deleted).
  def cancel
    @stock_count = find_count
    authorize @stock_count, :cancel?
    result = Inventory::StockCountRemoval.new(stock_count_id: @stock_count.id, actor: current_user,
                                              reason: params[:reason]).cancel!
    redirect_with(result, t("inventory.stock_counts.cancelled"))
  end

  # in_progress → completed (counter submits for approval; no stock change).
  def complete
    @stock_count = find_count
    authorize @stock_count, :complete?
    result = Inventory::StockCountCompletion.new(stock_count_id: @stock_count.id, actor: current_user).call
    redirect_with(result, t("inventory.stock_counts.completed"))
  end

  # completed → approved (approver). Posts the stock-count adjustment.
  def approve
    @stock_count = find_count
    authorize @stock_count, :approve?
    result = Inventory::StockCountApprover.new(stock_count_id: @stock_count.id, actor: current_user).call
    redirect_with(result, t("inventory.stock_counts.approved"))
  end

  # completed / approved → in_progress (approver). Reverses an approved
  # count's adjustment first.
  def reopen
    @stock_count = find_count
    authorize @stock_count, :reopen?
    result = Inventory::StockCountReopener.new(stock_count_id: @stock_count.id, actor: current_user,
                                               reason: params[:reason]).call
    redirect_with(result, t("inventory.stock_counts.reopened"))
  end

  def export
    @stock_count = find_count
    authorize @stock_count, :show?
    csv = Inventory::StockCountCsv.new(@stock_count)
    send_data csv.to_csv, filename: csv.filename, type: "text/csv"
  end

  def import
    @stock_count = find_count
    authorize @stock_count, :update?
  end

  def run_import
    @stock_count = find_count
    authorize @stock_count, :update?
    file = params[:file]
    if file.blank?
      redirect_to import_inventory_stock_count_path(@stock_count), alert: t("inventory.imports.no_file") and return
    end

    importer = Inventory::Imports::StockCountImporter.new(@stock_count, file.read, actor: current_user)
    result   = importer.call
    if result.ok?
      redirect_to inventory_stock_count_path(@stock_count),
                  notice: t("inventory.imports.count_summary", applied: result.applied_count, skipped: result.skipped_count)
    else
      redirect_to import_inventory_stock_count_path(@stock_count),
                  alert: importer.error.presence || t("inventory.imports.invalid_headers")
    end
  end

  private

  def find_count
    policy_scope(StockCount).find(params[:id])
  end

  def redirect_with(result, notice)
    if result.ok?
      redirect_to inventory_stock_count_path(@stock_count), notice: notice
    else
      redirect_to inventory_stock_count_path(@stock_count), alert: result.error
    end
  end

  def load_counting_screen
    @products = current_user.business.products.transactable.ordered
    ActiveRecord::Associations::Preloader.new(records: [ @stock_count ], associations: { items: :product }).call
    @live_on_hand = Inventory::StockAvailability
                      .on_hand_by(warehouse_ids: @stock_count.warehouse_id, product_ids: @stock_count.items.map(&:product_id))
                      .transform_keys(&:last)
  end

  # Header-only attributes used when creating a session.
  def session_params
    params.require(:stock_count).permit(:warehouse_id, :counted_on, :notes)
  end

  # Only counted quantities are editable on the counting screen; product_id
  # rides along for rows the barcode scanner adds on the fly, and
  # original_counted_quantity is the value the screen displayed (so an
  # unchanged row is recognised). A system quantity is never taken from the
  # client — the recorder reads the ledger.
  def count_entries
    attrs = params.require(:stock_count).permit(items_attributes: [ :id, :product_id, :counted_quantity, :original_counted_quantity ])
    (attrs[:items_attributes] || {}).to_h.values.map(&:symbolize_keys)
  end
end
