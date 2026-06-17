class Finance::ExpenseTypesController < Finance::BaseController
  before_action :set_type, only: %i[edit update destroy]

  def index
    authorize ExpenseType
    @types = policy_scope(ExpenseType).ordered.includes(:expense_category)
  end

  def new
    @type = current_user.business.expense_types.build(active: true)
    authorize @type
    load_categories
  end

  def create
    @type = current_user.business.expense_types.build(type_params)
    authorize @type
    if @type.save
      redirect_to finance_expense_types_path, notice: t("finance.types.created")
    else
      load_categories
      render :new, status: :unprocessable_entity
    end
  end

  def edit
    authorize @type
    load_categories
  end

  def update
    authorize @type
    if @type.update(type_params)
      redirect_to finance_expense_types_path, notice: t("finance.types.updated")
    else
      load_categories
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    authorize @type
    if @type.destroy
      redirect_to finance_expense_types_path, notice: t("finance.types.deleted")
    else
      redirect_to finance_expense_types_path,
                  alert: @type.errors.full_messages.to_sentence.presence || t("finance.types.delete_failed")
    end
  end

  private

  def set_type
    @type = policy_scope(ExpenseType).find(params[:id])
  end

  def load_categories
    @categories = current_user.business.expense_categories.active.ordered
  end

  def type_params
    params.require(:expense_type).permit(:expense_category_id, :name, :description, :active)
  end
end
