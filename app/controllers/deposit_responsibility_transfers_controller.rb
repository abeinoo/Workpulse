class DepositResponsibilityTransfersController < ApplicationController
  before_action :authenticate_user!
  before_action :set_transfer

  # GET /deposit_responsibility_transfers/:id
  def show
    authorize @transfer
  end

  # PATCH /deposit_responsibility_transfers/:id/accept
  def accept
    authorize @transfer

    result = Finance::DepositResponsibilityTransferAcceptor.new(@transfer, actor: current_user).call
    dest   = finance_daily_reconciliation_path(@transfer.daily_reconciliation)

    result.ok? ? redirect_to(dest, notice: t("deposit_responsibility_transfers.accepted")) :
                 redirect_to(dest, alert:  result.error)
  end

  # PATCH /deposit_responsibility_transfers/:id/cancel
  def cancel
    authorize @transfer

    result = Finance::DepositResponsibilityTransferCanceller.new(@transfer, actor: current_user).call
    dest   = finance_daily_reconciliation_path(@transfer.daily_reconciliation)

    result.ok? ? redirect_to(dest, notice: t("deposit_responsibility_transfers.cancelled")) :
                 redirect_to(dest, alert:  result.error)
  end

  private

  def set_transfer
    @transfer = DepositResponsibilityTransfer
                  .joins(:daily_reconciliation)
                  .where(daily_reconciliations: { business_id: current_user.business_id })
                  .includes(:daily_reconciliation, :from_user, :to_user)
                  .find(params[:id])
  end
end
