class Finance::ExpenseTagsController < Finance::BaseController
  before_action :set_tag, only: %i[edit update destroy]

  def index
    authorize ExpenseTag
    @tags = policy_scope(ExpenseTag).ordered
  end

  def new
    @tag = current_user.business.expense_tags.build(active: true)
    authorize @tag
  end

  def create
    @tag = current_user.business.expense_tags.build(tag_params)
    authorize @tag
    if @tag.save
      redirect_to finance_expense_tags_path, notice: t("finance.tags.created")
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
    authorize @tag
  end

  def update
    authorize @tag
    if @tag.update(tag_params)
      redirect_to finance_expense_tags_path, notice: t("finance.tags.updated")
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    authorize @tag
    @tag.destroy
    redirect_to finance_expense_tags_path, notice: t("finance.tags.deleted")
  end

  private

  def set_tag
    @tag = policy_scope(ExpenseTag).find(params[:id])
  end

  def tag_params
    params.require(:expense_tag).permit(:name, :active)
  end
end
