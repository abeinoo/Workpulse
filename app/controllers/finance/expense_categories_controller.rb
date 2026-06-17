class Finance::ExpenseCategoriesController < Finance::BaseController
  before_action :set_category, only: %i[edit update destroy]

  def index
    authorize ExpenseCategory
    @categories = policy_scope(ExpenseCategory).ordered.includes(:expense_types)
  end

  def new
    @category = current_user.business.expense_categories.build(active: true)
    authorize @category
  end

  def create
    @category = current_user.business.expense_categories.build(category_params)
    authorize @category
    if @category.save
      redirect_to finance_expense_categories_path, notice: t("finance.categories.created")
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
    authorize @category
  end

  def update
    authorize @category
    if @category.update(category_params)
      redirect_to finance_expense_categories_path, notice: t("finance.categories.updated")
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    authorize @category
    if @category.destroy
      redirect_to finance_expense_categories_path, notice: t("finance.categories.deleted")
    else
      redirect_to finance_expense_categories_path,
                  alert: @category.errors.full_messages.to_sentence.presence || t("finance.categories.delete_failed")
    end
  end

  private

  def set_category
    @category = policy_scope(ExpenseCategory).find(params[:id])
  end

  def category_params
    params.require(:expense_category).permit(:name, :description, :active)
  end
end
