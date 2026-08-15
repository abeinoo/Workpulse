class TillRefundsController < ApplicationController
  before_action :authenticate_user!

  # GET /till_refunds/new?daily_reconciliation_id=:id
  #
  # Refund is completely independent of Cashier Handover — the target
  # reconciliation always comes from daily_reconciliation_id (the DR being
  # acted on), never from the actor's own shift assignment, so Super Admin
  # and Area Manager can record a refund on a branch they don't personally
  # hold custody at. TillRefundPolicy is what actually gates who may act on
  # which branch.
  def new
    @reconciliation  = find_reconciliation(params[:daily_reconciliation_id])
    @refund          = TillRefund.new(daily_reconciliation: @reconciliation)
    @payment_methods = business_payment_methods
    @idempotency_key = SecureRandom.uuid

    authorize @refund
  end

  # POST /till_refunds
  def create
    @reconciliation = find_reconciliation(refund_params[:daily_reconciliation_id])
    @refund         = TillRefund.new(daily_reconciliation: @reconciliation)
    authorize @refund

    result = Finance::TillRefundCreator.new(
      @reconciliation.id,
      actor:  current_user,
      params: refund_params
    ).call

    if result.ok?
      redirect_to finance_daily_reconciliation_path(result.refund.daily_reconciliation),
                  notice: t("till_refunds.created")
    else
      @payment_methods = business_payment_methods
      # Preserve the same key on re-render so a retry of this exact failed
      # submission stays idempotent rather than minting a fresh one.
      @idempotency_key = refund_params[:idempotency_key].presence || SecureRandom.uuid
      flash.now[:alert] = result.error
      render :new, status: :unprocessable_entity
    end
  end

  private

  def find_reconciliation(id)
    DailyReconciliation.where(business_id: current_user.business_id).find(id)
  end

  def refund_params
    params.require(:till_refund).permit(
      :daily_reconciliation_id, :payment_method_id, :amount, :notes, :idempotency_key
    )
  end
end
