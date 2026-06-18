class Finance::CustodyTransactionsController < Finance::BaseController
  before_action :set_account

  def create
    # Build a record for authorization (checks the account is in the user's scope).
    record = @account.custody_transactions.build(business: @account.business, custody_account: @account)
    authorize record, :create?

    result = Finance::CustodyTransactionCreator.new(
      @account, actor: current_user, params: creator_params
    ).call

    back = safe_return_to || finance_custody_account_path(@account)
    if result.ok?
      redirect_to back, notice: t("finance.custody.transactions.created")
    else
      redirect_to back, alert: result.error
    end
  end

  def void
    transaction = @account.custody_transactions.find(params[:id])
    authorize transaction, :void?

    result = Finance::TransactionVoider.new(transaction, user: current_user, reason: params[:void_reason]).call
    if result.ok?
      redirect_to finance_custody_account_path(@account), notice: t("finance.custody.transactions.voided")
    else
      redirect_to finance_custody_account_path(@account), alert: result.error
    end
  end

  private

  def set_account
    @account = policy_scope(CustodyAccount).find(params[:custody_account_id])
  end

  def safe_return_to
    rt = params[:return_to].to_s
    rt if rt.start_with?("/finance/custody_accounts")
  end

  def creator_params
    {
      txn_type:             params[:txn_type],
      magnitude:            params[:magnitude],
      notes:                params[:notes],
      expense_id:           params[:expense_id],
      document:             params[:document],
      adjustment_direction: params[:adjustment_direction],
      target_account_id:    params[:target_account_id]
    }
  end
end
