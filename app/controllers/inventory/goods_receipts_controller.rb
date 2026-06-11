class Inventory::GoodsReceiptsController < Inventory::BaseController
  def index
    authorize GoodsReceipt
    @goods_receipts = policy_scope(GoodsReceipt).recent.includes(:supplier, :warehouse)
  end

  def show
    @goods_receipt = find_receipt
    authorize @goods_receipt
    @items = @goods_receipt.items.includes(:product)
  end

  def new
    @goods_receipt = current_user.business.goods_receipts.build(received_on: Date.current)
    @goods_receipt.items.build
    authorize @goods_receipt
    load_options
  end

  def create
    @goods_receipt = current_user.business.goods_receipts.build(receipt_params)
    @goods_receipt.created_by = current_user
    authorize @goods_receipt
    ensure_warehouses_accessible!(@goods_receipt.warehouse_id)

    result = Inventory::GoodsReceiptPoster.new(@goods_receipt).call
    if result.ok?
      redirect_to inventory_goods_receipt_path(@goods_receipt), notice: t("inventory.goods_receipts.created")
    else
      load_options
      @goods_receipt.items.build if @goods_receipt.items.empty?
      render :new, status: :unprocessable_entity
    end
  end

  def void
    @goods_receipt = find_receipt
    authorize @goods_receipt, :void?
    result = Inventory::DocumentVoider.new(@goods_receipt, user: current_user, reason: params[:void_reason]).call
    if result.ok?
      redirect_to inventory_goods_receipt_path(@goods_receipt), notice: t("inventory.goods_receipts.voided")
    else
      redirect_to inventory_goods_receipt_path(@goods_receipt),
                  alert: @goods_receipt.errors.full_messages.to_sentence.presence || t("inventory.void.failed")
    end
  end

  private

  def find_receipt
    policy_scope(GoodsReceipt).find(params[:id])
  end

  def load_options
    @warehouses = accessible_warehouses
    @suppliers  = current_user.business.suppliers.ordered
    @products   = current_user.business.products.ordered
  end

  def receipt_params
    params.require(:goods_receipt).permit(
      :warehouse_id, :supplier_id, :received_on, :notes, invoices: [],
      items_attributes: [ :id, :product_id, :quantity, :unit_cost, :_destroy ]
    )
  end
end
