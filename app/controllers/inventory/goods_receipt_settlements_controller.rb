class Inventory::GoodsReceiptSettlementsController < Inventory::BaseController
  def new
    @goods_receipt = find_receipt
    authorize @goods_receipt, :settle?
    @settlement_params = { source_kind: "company_cash", payment_date: Date.current }
    load_options
  end

  def create
    @goods_receipt = find_receipt
    authorize @goods_receipt, :settle?

    result = Inventory::GoodsReceiptSettlementRecorder.new(
      @goods_receipt.id, actor: current_user, params: settlement_params
    ).call

    if result.ok?
      redirect_to inventory_goods_receipt_path(@goods_receipt), notice: t("inventory.goods_receipts.settlements.recorded")
    else
      @settlement_params = settlement_params.to_h.symbolize_keys
      load_options
      flash.now[:alert] = result.error
      render :new, status: :unprocessable_entity
    end
  end

  def reverse
    @goods_receipt = find_receipt
    authorize @goods_receipt, :reverse_settlement?

    result = Inventory::GoodsReceiptSettlementReverser.new(
      goods_receipt_id: @goods_receipt.id, settlement_id: params[:id],
      actor: current_user, reason: params[:reversal_reason]
    ).call

    if result.ok?
      redirect_to inventory_goods_receipt_path(@goods_receipt), notice: t("inventory.goods_receipts.settlements.reversed")
    else
      redirect_to inventory_goods_receipt_path(@goods_receipt), alert: result.error
    end
  end

  private

  def find_receipt
    policy_scope(GoodsReceipt).includes(:supplier, :warehouse).find(params[:goods_receipt_id])
  end

  # Employee Custody is always the CURRENT user's own custody account (same
  # resolution as the goods receipt form and the recorder service). Its balance
  # is the authoritative ledger balance (Finance::CustodyBalance — SUM of
  # non-voided transactions), not the cached column; the service re-checks it
  # under lock on submit. nil account → the form explains and blocks custody.
  def load_options
    @settlement_total = @goods_receipt.settlement_total
    @settled_amount   = @goods_receipt.total_settled_amount
    @remaining_amount = [ @settlement_total - @settled_amount, 0 ].max

    @custody_account = current_user.custody_accounts.active.first
    @custody_balance = @custody_account && Finance::CustodyBalance.new(@custody_account).current
  end

  def settlement_params
    # No custody account id: the custody owner is always current_user.
    params.require(:settlement).permit(:source_kind, :amount, :payment_date, :reference, :notes)
  end
end
