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
    ActiveRecord::Associations::Preloader.new(records: [ @stock_count ], associations: { items: :product }).call
    @items            = @stock_count.items
    @product_barcodes = Product.barcode_lookup(@items.map(&:product_id))
  end

  def new
    @stock_count = current_user.business.stock_counts.build(counted_on: Date.current)
    authorize @stock_count
    @warehouses = accessible_warehouses
  end

  # Creating a session preloads a count row for every product in the business,
  # snapshotting the live on-hand per row so the counter sees the variance live.
  def create
    @stock_count = current_user.business.stock_counts.build(session_params)
    @stock_count.created_by = current_user
    authorize @stock_count
    ensure_warehouses_accessible!(@stock_count.warehouse_id)
    preload_products(@stock_count)

    if @stock_count.save
      redirect_to edit_inventory_stock_count_path(@stock_count), notice: t("inventory.stock_counts.created")
    else
      @warehouses = accessible_warehouses
      render :new, status: :unprocessable_entity
    end
  end

  # The counting screen.
  def edit
    @stock_count = find_count
    authorize @stock_count
    @products = current_user.business.products.transactable.ordered
  end

  # Saving counted quantities; the first save moves draft → in_progress.
  def update
    @stock_count = find_count
    authorize @stock_count
    ActiveRecord::Base.transaction do
      @stock_count.update!(counts_params)
      @stock_count.start_counting!(current_user)
    end
    redirect_to inventory_stock_count_path(@stock_count), notice: t("inventory.stock_counts.updated")
  rescue ActiveRecord::RecordInvalid
    @products = current_user.business.products.transactable.ordered
    render :edit, status: :unprocessable_entity
  end

  def destroy
    @stock_count = find_count
    authorize @stock_count
    @stock_count.destroy
    redirect_to inventory_stock_counts_path, notice: t("inventory.stock_counts.deleted")
  end

  # in_progress → completed (counter submits for approval).
  def complete
    @stock_count = find_count
    authorize @stock_count, :complete?
    if @stock_count.mark_completed!(current_user)
      redirect_to inventory_stock_count_path(@stock_count), notice: t("inventory.stock_counts.completed")
    else
      redirect_to inventory_stock_count_path(@stock_count), alert: t("inventory.stock_counts.complete_failed")
    end
  end

  # completed → approved (approver). Generates the stock-count adjustment.
  def approve
    @stock_count = find_count
    authorize @stock_count, :approve?
    result = Inventory::StockCountApprover.new(@stock_count, user: current_user).call
    if result.ok?
      redirect_to inventory_stock_count_path(@stock_count), notice: t("inventory.stock_counts.approved")
    else
      redirect_to inventory_stock_count_path(@stock_count),
                  alert: @stock_count.errors.full_messages.to_sentence.presence || t("inventory.stock_counts.approve_failed")
    end
  end

  # completed → in_progress (approver sends it back for recount).
  def reopen
    @stock_count = find_count
    authorize @stock_count, :reopen?
    @stock_count.reopen!
    redirect_to inventory_stock_count_path(@stock_count), notice: t("inventory.stock_counts.reopened")
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

    result = Inventory::Imports::StockCountImporter.new(@stock_count, file.read).call
    if result.ok?
      @stock_count.start_counting!(current_user)
      redirect_to inventory_stock_count_path(@stock_count),
                  notice: t("inventory.imports.count_summary", applied: result.applied_count, skipped: result.skipped_count)
    else
      redirect_to import_inventory_stock_count_path(@stock_count), alert: t("inventory.imports.invalid_headers")
    end
  end

  private

  def find_count
    policy_scope(StockCount).find(params[:id])
  end

  # Build a count row for every product, snapshotting its on-hand in the warehouse.
  def preload_products(count)
    return if count.warehouse.nil?
    current_user.business.products.transactable.ordered.each do |product|
      count.items.build(product: product, system_quantity: product.stock_in(count.warehouse))
    end
  end

  # Header-only attributes used when creating a session.
  def session_params
    params.require(:stock_count).permit(:warehouse_id, :counted_on, :notes)
  end

  # Only counted quantities are editable on the counting screen; product_id /
  # system_quantity ride along for rows the barcode scanner adds on the fly.
  def counts_params
    params.require(:stock_count).permit(
      :notes,
      items_attributes: [ :id, :product_id, :counted_quantity, :system_quantity ]
    )
  end
end
