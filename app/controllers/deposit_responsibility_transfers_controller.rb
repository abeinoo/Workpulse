class DepositResponsibilityTransfersController < ApplicationController
  before_action :authenticate_user!
  before_action :set_transfer

  # GET /deposit_responsibility_transfers/:id
  def show
    authorize @transfer

    dr = @transfer.daily_reconciliation
    cash_amounts = dr.session_amounts.select { |sa| sa.payment_method.cash_like? }

    already_deposited_by_pm = dr.till_deposits
                                 .select { |d| d.voided_at.nil? }
                                 .each_with_object(Hash.new(0)) do |dep, h|
                                   h[dep.payment_method_id] += dep.amount
                                 end

    @session_summary = cash_amounts.map do |sa|
      expected  = sa.net_amount
      deposited = already_deposited_by_pm[sa.payment_method_id]
      remaining = [expected - deposited, 0].max
      { name: sa.payment_method_name, expected: expected, deposited: deposited, remaining: remaining }
    end

    @total_expected  = @session_summary.sum { |r| r[:expected] }
    @total_deposited = @session_summary.sum { |r| r[:deposited] }
    @total_remaining = [@total_expected - @total_deposited, 0].max
  end

  # PATCH /deposit_responsibility_transfers/:id/accept
  def accept
    authorize @transfer

    result = Finance::DepositResponsibilityTransferAcceptor.new(@transfer.id, actor: current_user).call
    dest   = finance_daily_reconciliation_path(@transfer.daily_reconciliation)

    result.ok? ? redirect_to(dest, notice: t("deposit_responsibility_transfers.accepted")) :
                 redirect_to(dest, alert:  result.error)
  end

  # PATCH /deposit_responsibility_transfers/:id/cancel
  def cancel
    authorize @transfer

    result = Finance::DepositResponsibilityTransferCanceller.new(@transfer.id, actor: current_user).call
    dest   = finance_daily_reconciliation_path(@transfer.daily_reconciliation)

    result.ok? ? redirect_to(dest, notice: t("deposit_responsibility_transfers.cancelled")) :
                 redirect_to(dest, alert:  result.error)
  end

  private

  def set_transfer
    @transfer = DepositResponsibilityTransfer
                  .joins(:daily_reconciliation)
                  .where(daily_reconciliations: { business_id: current_user.business_id })
                  .includes(
                    :from_user, :to_user,
                    daily_reconciliation: [
                      :branch,
                      :till_session,
                      { session_amounts: :payment_method },
                      :till_deposits
                    ]
                  )
                  .find(params[:id])
  end
end
