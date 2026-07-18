class Inventory::GoodsReceiptsController < Inventory::BaseController
  def index
    authorize GoodsReceipt
    @goods_receipts = policy_scope(GoodsReceipt).recent.includes(:supplier, :warehouse)
  end

  def show
    @goods_receipt = find_receipt
    authorize @goods_receipt
    @items       = @goods_receipt.items.includes(:product)
    @settlements = @goods_receipt.financial_settlements.chronological.includes(:funding_source, :created_by)
    @audit_logs  = AuditLog.for_auditable(@goods_receipt).recent.includes(:actor)
  end

  def new
    @goods_receipt = current_user.business.goods_receipts.build(received_on: Date.current, funding_source_kind: "employee_custody")
    @goods_receipt.items.build
    authorize @goods_receipt
    load_options
  end

  def create
    @goods_receipt = current_user.business.goods_receipts.build(receipt_params)
    @goods_receipt.created_by = current_user
    assign_funding_source
    authorize @goods_receipt
    ensure_warehouses_accessible!(@goods_receipt.warehouse_id)

    result = Inventory::GoodsReceiptDraftService.new(@goods_receipt, actor: current_user).call
    if result.ok?
      redirect_to inventory_goods_receipt_path(@goods_receipt), notice: t("inventory.goods_receipts.created")
    else
      load_options
      @goods_receipt.items.build if @goods_receipt.items.empty?
      render :new, status: :unprocessable_entity
    end
  end

  def edit
    @goods_receipt = find_receipt
    authorize @goods_receipt
    load_options
  end

  def update
    @goods_receipt = find_receipt
    authorize @goods_receipt
    @goods_receipt.assign_attributes(receipt_params)
    assign_funding_source
    ensure_warehouses_accessible!(@goods_receipt.warehouse_id)

    result = Inventory::GoodsReceiptDraftService.new(@goods_receipt, actor: current_user).call
    if result.ok?
      redirect_to inventory_goods_receipt_path(@goods_receipt), notice: t("inventory.goods_receipts.updated")
    else
      load_options
      render :edit, status: :unprocessable_entity
    end
  end

  def submit
    @goods_receipt = find_receipt
    authorize @goods_receipt, :submit_for_approval?
    result = Inventory::GoodsReceiptApproval.new(goods_receipt_id: @goods_receipt.id, actor: current_user).submit!
    redirect_with_result(result, ok_message: t("inventory.goods_receipts.submitted"))
  end

  def approve
    @goods_receipt = find_receipt
    authorize @goods_receipt, :approve?
    result = Inventory::GoodsReceiptApproval.new(goods_receipt_id: @goods_receipt.id, actor: current_user).approve!
    redirect_with_result(result, ok_message: t("inventory.goods_receipts.approved"))
  end

  def reject
    @goods_receipt = find_receipt
    authorize @goods_receipt, :reject?
    result = Inventory::GoodsReceiptApproval.new(goods_receipt_id: @goods_receipt.id, actor: current_user)
                                            .reject!(reason: params[:rejection_reason])
    redirect_with_result(result, ok_message: t("inventory.goods_receipts.rejected"))
  end

  def confirm
    @goods_receipt = find_receipt
    authorize @goods_receipt, :confirm?
    result = Inventory::GoodsReceiptConfirmationService.new(goods_receipt_id: @goods_receipt.id, actor: current_user).call
    redirect_with_result(result, ok_message: t("inventory.goods_receipts.confirmed"))
  end

  def void
    @goods_receipt = find_receipt
    authorize @goods_receipt, :void?
    result = Inventory::GoodsReceiptVoider.new(goods_receipt_id: @goods_receipt.id, actor: current_user, reason: params[:void_reason]).call
    if result.ok?
      redirect_to inventory_goods_receipt_path(@goods_receipt), notice: t("inventory.goods_receipts.voided")
    else
      redirect_to inventory_goods_receipt_path(@goods_receipt),
                  alert: result.error.presence || @goods_receipt.errors.full_messages.to_sentence.presence || t("inventory.void.failed")
    end
  end

  private

  def find_receipt
    policy_scope(GoodsReceipt).find(params[:id])
  end

  def redirect_with_result(result, ok_message:)
    if result.ok?
      redirect_to inventory_goods_receipt_path(@goods_receipt), notice: ok_message
    else
      redirect_to inventory_goods_receipt_path(@goods_receipt), alert: result.error
    end
  end

  def load_options
    @warehouses      = accessible_warehouses
    @suppliers       = current_user.business.suppliers.ordered
    @products        = current_user.business.products.transactable.ordered
    @custody_account = current_user.custody_accounts.active.first
  end

  # Employee Custody always means the acting user's own account — never a
  # selectable employee. Ignoring any client-supplied account id here is what
  # makes "never allow selecting another employee" actually true server-side.
  def assign_funding_source
    return unless @goods_receipt.funding_source_kind == "employee_custody"

    @goods_receipt.funding_source = current_user.custody_accounts.active.first
  end

  def receipt_params
    params.require(:goods_receipt).permit(
      :warehouse_id, :supplier_id, :received_on, :notes, :funding_source_kind, invoices: [],
      items_attributes: [ :id, :product_id, :quantity, :unit_cost, :_destroy ]
    )
  end
end
