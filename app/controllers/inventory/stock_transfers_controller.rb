class Inventory::StockTransfersController < Inventory::BaseController
  def index
    authorize StockTransfer
    @stock_transfers = policy_scope(StockTransfer).recent
                                                  .includes(:source_warehouse, :destination_warehouse)
  end

  def show
    @stock_transfer = find_transfer
    authorize @stock_transfer
    @items = @stock_transfer.items.includes(:product)
  end

  def new
    @stock_transfer = current_user.business.stock_transfers.build(transferred_on: Date.current)
    @stock_transfer.items.build
    authorize @stock_transfer
    load_options
  end

  def create
    @stock_transfer = current_user.business.stock_transfers.build(transfer_params)
    @stock_transfer.created_by = current_user
    authorize @stock_transfer
    ensure_warehouses_accessible!(@stock_transfer.source_warehouse_id, @stock_transfer.destination_warehouse_id)

    result = Inventory::StockTransferPoster.new(@stock_transfer).call
    if result.ok?
      redirect_to inventory_stock_transfer_path(@stock_transfer), notice: t("inventory.stock_transfers.created")
    else
      load_options
      @stock_transfer.items.build if @stock_transfer.items.empty?
      render :new, status: :unprocessable_entity
    end
  end

  def void
    @stock_transfer = find_transfer
    authorize @stock_transfer, :void?
    result = Inventory::DocumentVoider.new(@stock_transfer, user: current_user, reason: params[:void_reason]).call
    if result.ok?
      redirect_to inventory_stock_transfer_path(@stock_transfer), notice: t("inventory.stock_transfers.voided")
    else
      redirect_to inventory_stock_transfer_path(@stock_transfer),
                  alert: @stock_transfer.errors.full_messages.to_sentence.presence || t("inventory.void.failed")
    end
  end

  private

  def find_transfer
    policy_scope(StockTransfer).find(params[:id])
  end

  def load_options
    @warehouses = accessible_warehouses
    @products   = current_user.business.products.transactable.ordered
  end

  def transfer_params
    params.require(:stock_transfer).permit(
      :source_warehouse_id, :destination_warehouse_id, :transferred_on, :notes,
      items_attributes: [ :id, :product_id, :quantity, :_destroy ]
    )
  end
end
