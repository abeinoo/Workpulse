class Inventory::StockCountsController < Inventory::BaseController
  def index
    authorize StockCount
    @stock_counts = policy_scope(StockCount).recent.includes(:warehouse, :created_by, :posted_by)
    @stock_counts = @stock_counts.where(warehouse_id: params[:warehouse_id]) if params[:warehouse_id].present?
    @stock_counts = @stock_counts.where(status: params[:status])             if params[:status].present?
    @warehouses   = accessible_warehouses
  end

  def show
    @stock_count = find_count
    authorize @stock_count
    @items = @stock_count.items.includes(:product)
  end

  def new
    @stock_count = current_user.business.stock_counts.build(counted_on: Date.current)
    @stock_count.items.build
    authorize @stock_count
    load_options
  end

  def create
    @stock_count = current_user.business.stock_counts.build(stock_count_params)
    @stock_count.created_by = current_user
    authorize @stock_count
    ensure_warehouses_accessible!(@stock_count.warehouse_id)
    snapshot_system_quantities(@stock_count)

    if @stock_count.save
      redirect_to inventory_stock_count_path(@stock_count), notice: t("inventory.stock_counts.created")
    else
      load_options
      @stock_count.items.build if @stock_count.items.empty?
      render :new, status: :unprocessable_entity
    end
  end

  def edit
    @stock_count = find_count
    authorize @stock_count
    load_options
  end

  def update
    @stock_count = find_count
    authorize @stock_count
    @stock_count.assign_attributes(stock_count_params)
    ensure_warehouses_accessible!(@stock_count.warehouse_id)
    snapshot_system_quantities(@stock_count)

    if @stock_count.save
      redirect_to inventory_stock_count_path(@stock_count), notice: t("inventory.stock_counts.updated")
    else
      load_options
      @stock_count.items.build if @stock_count.items.empty?
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @stock_count = find_count
    authorize @stock_count
    @stock_count.destroy
    redirect_to inventory_stock_counts_path, notice: t("inventory.stock_counts.deleted")
  end

  def post
    @stock_count = find_count
    authorize @stock_count, :post?
    result = Inventory::StockCountPoster.new(@stock_count, user: current_user).call
    if result.ok?
      redirect_to inventory_stock_count_path(@stock_count), notice: t("inventory.stock_counts.posted")
    else
      redirect_to inventory_stock_count_path(@stock_count),
                  alert: @stock_count.errors.full_messages.to_sentence.presence || t("inventory.stock_counts.post_failed")
    end
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

  def load_options
    @warehouses = accessible_warehouses
    @products   = current_user.business.products.ordered
  end

  # Snapshot the live on-hand for each line so the worksheet shows the variance.
  # (Re-snapshotted authoritatively at post time by StockCountPoster.)
  def snapshot_system_quantities(count)
    return if count.warehouse.nil?
    count.items.reject(&:marked_for_destruction?).each do |item|
      next if item.product.nil?
      item.system_quantity = item.product.stock_in(count.warehouse)
    end
  end

  def stock_count_params
    params.require(:stock_count).permit(
      :warehouse_id, :counted_on, :notes,
      items_attributes: [ :id, :product_id, :counted_quantity, :_destroy ]
    )
  end
end
