class Finance::ExpensePaymentsController < Finance::BaseController
  def new
    @expense = find_expense
    authorize @expense, :record_payment?
    load_eligible_custody_account
  end

  def create
    @expense = find_expense
    authorize @expense, :record_payment?

    result = Finance::ExpensePaymentRecorder.new(
      @expense.id, actor: current_user, params: payment_params
    ).call

    if result.ok?
      redirect_to finance_expense_path(@expense), notice: t("finance.expenses.payment_recorded")
    else
      load_eligible_custody_account
      flash.now[:alert] = result.error
      render :new, status: :unprocessable_entity
    end
  end

  private

  def find_expense
    policy_scope(Expense).find(params[:expense_id])
  end

  # "Paid from my balance" is optional and always the CURRENT actor's own
  # account — the person recording this specific payment, independent of who
  # created the expense or funded any other payment on it. Only shown when
  # that account actually exists.
  def load_eligible_custody_account
    @eligible_custody_account = current_user_balance_account
  end

  def payment_params
    params.require(:payment).permit(:paid_from_balance, :amount, :payment_date, :notes)
  end
end
