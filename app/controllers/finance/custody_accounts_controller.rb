class Finance::CustodyAccountsController < Finance::BaseController
  before_action :set_account, only: %i[show edit update destroy]

  def index
    authorize CustodyAccount
    @finance_view = current_user.can?(:view_employee_balances) || current_user.can?(:manage_employee_balances)

    if @finance_view
      @accounts          = policy_scope(CustodyAccount).includes(:user, :branch).ordered
      @last_activity     = CustodyTransaction
                             .where(custody_account_id: @accounts.map(&:id))
                             .group(:custody_account_id)
                             .maximum(:created_at)
      @balance_requests  = policy_scope(BalanceRequest)
                             .includes(:created_by, :branch)
                             .recent
                             .limit(30)
    else
      @my_account   = policy_scope(CustodyAccount).active.first
      @balance      = @my_account ? Finance::CustodyBalance.new(@my_account).current : 0
      @transactions = @my_account ? @my_account.custody_transactions
                                      .includes(:expense, :created_by).recent.limit(50)
                                  : []
    end

    @my_requests = policy_scope(BalanceRequest).recent
                     .includes(:created_by, :branch).limit(20)
  end

  def show
    authorize @account
    @balance          = Finance::CustodyBalance.new(@account).current
    @transactions     = @account.custody_transactions.includes(:expense, :created_by).recent.limit(100)
    @new_transaction  = @account.custody_transactions.build
    @other_accounts   = policy_scope(CustodyAccount).active.where.not(id: @account.id).ordered
    @balance_requests = policy_scope(BalanceRequest)
                          .where(created_by: @account.user)
                          .includes(:created_by)
                          .recent
                          .limit(15)
  end

  def new
    @account = current_user.business.custody_accounts.build(active: true)
    authorize @account
    load_options
  end

  def create
    @account = current_user.business.custody_accounts.build(account_params)
    authorize @account
    if @account.save
      redirect_to finance_custody_account_path(@account), notice: t("finance.custody.accounts.created")
    else
      load_options
      render :new, status: :unprocessable_entity
    end
  end

  def edit
    authorize @account
    load_options
  end

  def update
    authorize @account
    if @account.update(account_params)
      redirect_to finance_custody_account_path(@account), notice: t("finance.custody.accounts.updated")
    else
      load_options
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    authorize @account
    if @account.destroy
      redirect_to finance_custody_accounts_path, notice: t("finance.custody.accounts.deleted")
    else
      redirect_to finance_custody_account_path(@account),
                  alert: @account.errors.full_messages.to_sentence.presence || t("finance.custody.accounts.delete_failed")
    end
  end

  private

  def set_account
    @account = policy_scope(CustodyAccount).find(params[:id])
  end

  def load_options
    @users    = current_user.business.users.order(:first_name, :last_name)
    @branches = assignable_branches
  end

  def account_params
    params.require(:custody_account).permit(:user_id, :branch_id, :name, :active)
  end
end
