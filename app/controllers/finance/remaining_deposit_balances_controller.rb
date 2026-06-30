class Finance::RemainingDepositBalancesController < Finance::BaseController
  before_action :set_balance, only: %i[show settle write_off reassign]

  # GET /finance/remaining_deposit_balances/:id
  def show
    authorize @balance
    if @balance.open?
      @business_users  = current_user.business.users.active.order(:first_name)
      @payment_methods = business_payment_methods
    end
  end

  # PATCH /finance/remaining_deposit_balances/:id/settle
  def settle
    authorize @balance, :settle?

    result = Finance::RemainingDepositBalanceSettler.new(
      @balance.id,
      actor:             current_user,
      amount:            params[:amount],
      notes:             params[:notes],
      payment_method_id: params[:payment_method_id],
      reference_number:  params[:reference_number]
    ).call

    if result.ok?
      notice = result.balance.open? ? t("remaining_deposit_balances.partial_settled") : t("remaining_deposit_balances.settled")
      redirect_to finance_remaining_deposit_balance_path(@balance), notice: notice
    else
      flash.now[:alert]  = result.error
      @business_users    = current_user.business.users.active.order(:first_name)
      @payment_methods   = business_payment_methods
      render :show, status: :unprocessable_entity
    end
  end

  # PATCH /finance/remaining_deposit_balances/:id/write_off
  def write_off
    authorize @balance, :write_off?

    result = Finance::RemainingDepositBalanceWriteOff.new(
      @balance.id,
      actor:  current_user,
      notes:  params[:notes]
    ).call

    if result.ok?
      redirect_to finance_remaining_deposit_balance_path(@balance),
                  notice: t("remaining_deposit_balances.written_off")
    else
      flash.now[:alert]  = result.error
      @business_users    = current_user.business.users.active.order(:first_name)
      @payment_methods   = business_payment_methods
      render :show, status: :unprocessable_entity
    end
  end

  # PATCH /finance/remaining_deposit_balances/:id/reassign
  def reassign
    authorize @balance, :reassign?

    result = Finance::RemainingDepositBalanceReassigner.new(
      @balance.id,
      actor:       current_user,
      new_user_id: params[:new_responsible_user_id],
      notes:       params[:notes]
    ).call

    if result.ok?
      redirect_to finance_remaining_deposit_balance_path(@balance),
                  notice: t("remaining_deposit_balances.reassigned")
    else
      flash.now[:alert]  = result.error
      @business_users    = current_user.business.users.active.order(:first_name)
      @payment_methods   = business_payment_methods
      render :show, status: :unprocessable_entity
    end
  end

  private

  def set_balance
    @balance = policy_scope(RemainingDepositBalance)
                 .includes(:daily_reconciliation, :responsible_user, :created_by,
                            till_deposit:          :payment_method,
                            daily_reconciliation:  :branch,
                            balance_transactions:  %i[performed_by
                                                       previous_responsible_user
                                                       new_responsible_user
                                                       payment_method])
                 .find(params[:id])
  end
end
