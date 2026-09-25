class DepositResponsibilityTransfersController < ApplicationController
  before_action :authenticate_user!
  before_action :set_transfer, except: :create
  before_action :require_pending, only: %i[accept reject_form reject cancel]

  # GET /deposit_responsibility_transfers/:id
  def show
    authorize @transfer

    dr = @transfer.daily_reconciliation
    cash_amounts     = dr.session_amounts.select { |sa| sa.payment_method.cash_like? }
    remaining_by_pm  = dr.remaining_by_payment_method
    deposited_by_pm  = dr.till_deposits.active.group_by(&:payment_method_id)
                          .transform_values { |deps| deps.sum(&:amount) }

    # expected/deposited/remaining per payment method — remaining always
    # delegates to DailyReconciliation#remaining_by_payment_method (the same
    # figure the Record Deposit dialog and TillDepositRecorder use), so an
    # open ATM Deposit Dispute is reflected here exactly as everywhere else,
    # never recomputed independently.
    @session_summary = cash_amounts.map do |sa|
      {
        name:      sa.payment_method_name,
        expected:  sa.net_amount,
        deposited: deposited_by_pm[sa.payment_method_id] || 0,
        remaining: remaining_by_pm[sa.payment_method_id] || 0
      }
    end

    @total_expected  = @session_summary.sum { |r| r[:expected] }
    @total_deposited = @session_summary.sum { |r| r[:deposited] }
    @total_remaining = dr.pending_deposit_amount
  end

  # POST /deposit_responsibility_transfers
  # Manager-initiated transfer from the DR page. Creates a PENDING transfer;
  # the current depositor stays responsible until the recipient accepts.
  def create
    dr = policy_scope(DailyReconciliation).find(params[:daily_reconciliation_id])
    authorize dr, :transfer_deposit_responsibility?

    result = Finance::DepositResponsibilityTransferRequester.new(
      dr.id,
      actor:                 current_user,
      to_user_id:            params[:to_user_id],
      expected_depositor_id: params[:expected_depositor_id],
      notes:                 params[:notes]
    ).call

    if result.ok?
      redirect_to finance_daily_reconciliation_path(dr),
                  notice: t("deposit_responsibility_transfers.requested", name: result.transfer.to_user.full_name)
    else
      redirect_to finance_daily_reconciliation_path(dr), alert: result.error
    end
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

  # GET /deposit_responsibility_transfers/:id/reject_form
  def reject_form
    authorize @transfer, :reject?
  end

  # PATCH /deposit_responsibility_transfers/:id/reject
  def reject
    authorize @transfer

    result = Finance::DepositResponsibilityTransferRejecter.new(
      @transfer.id, actor: current_user, reason: params[:rejection_reason]
    ).call
    dest = finance_daily_reconciliation_path(@transfer.daily_reconciliation)

    result.ok? ? redirect_to(dest, notice: t("deposit_responsibility_transfers.rejected")) :
                 redirect_to(dest, alert:  result.error)
  end

  private

  # A second tab (or a late click) acting on a transfer that was already
  # accepted/rejected/cancelled gets told exactly that, not a generic
  # "not authorized" — the policies below all require pending?. The services
  # re-check under the DR lock for the true race.
  def require_pending
    return if @transfer.pending?

    key =
      case
      when @transfer.accepted? then "already_accepted"
      when @transfer.rejected? then "rejected"
      else "cancelled"
      end
    redirect_to finance_daily_reconciliation_path(@transfer.daily_reconciliation),
                alert: t("deposit_responsibility_transfers.errors.#{key}")
  end

  def set_transfer
    @transfer = DepositResponsibilityTransfer
                  .joins(:daily_reconciliation)
                  .where(daily_reconciliations: { business_id: current_user.business_id })
                  .includes(
                    :from_user, :to_user, :initiated_by, :accepted_by,
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
