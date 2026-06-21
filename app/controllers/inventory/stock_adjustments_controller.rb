class Inventory::StockAdjustmentsController < Inventory::BaseController
  def index
    authorize StockAdjustment
    @stock_adjustments = policy_scope(StockAdjustment).recent.includes(:warehouse)
  end

  def show
    @stock_adjustment = find_adjustment
    authorize @stock_adjustment
    @items = @stock_adjustment.items.includes(:product)

    # For stock-count adjustments, surface the originating count so the page can
    # link back and show the System/Counted/Difference behind each line.
    @source_count = @stock_adjustment.source_stock_count
    @count_items_by_product = @source_count ? @source_count.items.index_by(&:product_id) : {}
  end

  def new
    @stock_adjustment = current_user.business.stock_adjustments.build(
      adjusted_on: Date.current, reason: "stock_count"
    )
    @stock_adjustment.items.build
    authorize @stock_adjustment
    load_options
  end

  def create
    @stock_adjustment = current_user.business.stock_adjustments.build(adjustment_params)
    @stock_adjustment.created_by = current_user
    authorize @stock_adjustment
    ensure_warehouses_accessible!(@stock_adjustment.warehouse_id)

    result = Inventory::AdjustmentPoster.new(@stock_adjustment).call
    if result.ok?
      redirect_to inventory_stock_adjustment_path(@stock_adjustment), notice: t("inventory.stock_adjustments.created")
    else
      load_options
      @stock_adjustment.items.build if @stock_adjustment.items.empty?
      render :new, status: :unprocessable_entity
    end
  end

  def void
    @stock_adjustment = find_adjustment
    authorize @stock_adjustment, :void?
    result = Inventory::DocumentVoider.new(@stock_adjustment, user: current_user, reason: params[:void_reason]).call
    if result.ok?
      redirect_to inventory_stock_adjustment_path(@stock_adjustment), notice: t("inventory.stock_adjustments.voided")
    else
      redirect_to inventory_stock_adjustment_path(@stock_adjustment),
                  alert: @stock_adjustment.errors.full_messages.to_sentence.presence || t("inventory.void.failed")
    end
  end

  private

  def find_adjustment
    policy_scope(StockAdjustment).find(params[:id])
  end

  def load_options
    @warehouses = accessible_warehouses
    @products   = current_user.business.products.transactable.ordered
  end

  def adjustment_params
    params.require(:stock_adjustment).permit(
      :warehouse_id, :adjusted_on, :reason, :notes,
      items_attributes: [ :id, :product_id, :quantity_difference, :unit_cost, :_destroy ]
    )
  end
end
