class Finance::BranchRevenuesController < Finance::BaseController
  before_action :set_revenue, only: %i[edit update destroy]

  def index
    authorize BranchRevenue
    @revenues = policy_scope(BranchRevenue).includes(:branch).recent
  end

  def new
    @revenue = current_user.business.branch_revenues.build(period_month: Date.current.beginning_of_month)
    authorize @revenue
    load_branches
  end

  def create
    @revenue = current_user.business.branch_revenues.build(revenue_params)
    @revenue.created_by = current_user
    authorize @revenue
    if @revenue.save
      redirect_to finance_branch_revenues_path, notice: t("finance.branch_revenues.created")
    else
      load_branches
      render :new, status: :unprocessable_entity
    end
  end

  def edit
    authorize @revenue
    load_branches
  end

  def update
    authorize @revenue
    if @revenue.update(revenue_params)
      redirect_to finance_branch_revenues_path, notice: t("finance.branch_revenues.updated")
    else
      load_branches
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    authorize @revenue
    @revenue.destroy
    redirect_to finance_branch_revenues_path, notice: t("finance.branch_revenues.deleted")
  end

  private

  def set_revenue
    @revenue = policy_scope(BranchRevenue).find(params[:id])
  end

  def load_branches
    @branches = assignable_branches
  end

  def revenue_params
    params.require(:branch_revenue).permit(:branch_id, :period_month, :amount, :notes)
  end
end
