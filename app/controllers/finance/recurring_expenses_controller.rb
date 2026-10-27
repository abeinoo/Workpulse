class Finance::RecurringExpensesController < Finance::BaseController
  before_action :set_recurring, only: %i[show edit update destroy generate]

  def index
    authorize RecurringExpense
    @recurring_expenses = policy_scope(RecurringExpense)
                          .includes(:branch, :expense_category, :expense_type)
                          .ordered
  end

  def show
    authorize @recurring
    @generated = @recurring.generated_expenses.recent.includes(:branch).limit(20)
  end

  def new
    @recurring = current_user.business.recurring_expenses.build(active: true,
                                                                start_date: Date.current,
                                                                frequency: "monthly")
    authorize @recurring
    load_options
  end

  def create
    @recurring = current_user.business.recurring_expenses.build(recurring_params)
    @recurring.created_by = current_user
    @recurring.next_run_on ||= @recurring.start_date
    authorize @recurring

    if @recurring.save
      redirect_to finance_recurring_expense_path(@recurring), notice: t("finance.recurring.created")
    else
      load_options
      render :new, status: :unprocessable_entity
    end
  end

  def edit
    authorize @recurring
    load_options
  end

  def update
    authorize @recurring
    if @recurring.update(recurring_params)
      redirect_to finance_recurring_expense_path(@recurring), notice: t("finance.recurring.updated")
    else
      load_options
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    authorize @recurring
    @recurring.destroy
    redirect_to finance_recurring_expenses_path, notice: t("finance.recurring.deleted")
  end

  # Manual "generate now" — forces one pending expense for the current period.
  def generate
    authorize @recurring, :generate?
    result = Finance::RecurringExpenseGenerator.new(@recurring, force: true).call
    if result.ok?
      redirect_to finance_expense_path(result.expense), notice: t("finance.recurring.generated")
    else
      redirect_to finance_recurring_expense_path(@recurring),
                  alert: t("finance.recurring.generate_failed", reason: result.reason)
    end
  end

  private

  def set_recurring
    @recurring = policy_scope(RecurringExpense).find(params[:id])
  end

  def load_options
    @categories = current_user.business.expense_categories.active.ordered
    @types      = current_user.business.expense_types.active.ordered
    @branches   = assignable_branches
  end

  def recurring_params
    params.require(:recurring_expense).permit(
      :branch_id, :expense_category_id, :expense_type_id, :amount, :frequency,
      :start_date, :end_date, :next_run_on, :active,
      recurring_expense_allocations_attributes: [ :id, :branch_id, :allocation_percentage, :_destroy ]
    )
  end
end
