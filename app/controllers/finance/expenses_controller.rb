class Finance::ExpensesController < Finance::BaseController
  def index
    authorize Expense
    @expenses = policy_scope(Expense)
                .with_status(params[:status])
                .for_branch(params[:branch_id])
                .for_category(params[:expense_category_id])
                .for_type(params[:expense_type_id])
                .on_or_after(params[:from])
                .on_or_before(params[:to])
                .recent
                .includes(:branch, :expense_category, :expense_type, :created_by)
    @expenses = @expenses.where(created_by_id: params[:created_by_id]) if params[:created_by_id].present?
    @filter_branches    = assignable_branches
    @filter_categories  = current_user.business.expense_categories.active.ordered
    @filter_types       = current_user.business.expense_types.active.ordered
    @filter_creators    = User.where(
                            id: Expense.where(business: current_user.business).select(:created_by_id)
                          ).order(:first_name, :last_name)
  end

  def show
    @expense = find_expense
    authorize @expense
    @allocations = @expense.expense_allocations.includes(:branch)
    @audit_logs  = AuditLog.for_auditable(@expense).recent
  end

  def new
    @expense = current_user.business.expenses.build(expense_date: Date.current)
    auto_assign_branch_from_balance_account(@expense)
    authorize @expense
    load_options
  end

  def create
    @expense = current_user.business.expenses.build(expense_params)
    @expense.created_by = current_user
    auto_assign_branch_from_balance_account(@expense)
    authorize @expense

    if save_expense
      redirect_to finance_expense_path(@expense), notice: t("finance.expenses.created")
    else
      load_options
      render :new, status: :unprocessable_entity
    end
  end

  def edit
    @expense = find_expense
    authorize @expense, :update?
    load_options
  end

  def update
    @expense = find_expense
    authorize @expense, :update?
    @expense.assign_attributes(expense_params)

    if save_expense
      redirect_to finance_expense_path(@expense), notice: t("finance.expenses.updated")
    else
      load_options
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @expense = find_expense
    authorize @expense, :destroy?
    @expense.destroy
    redirect_to finance_expenses_path, notice: t("finance.expenses.deleted")
  end

  def submit  = run_transition(:submit?,  :submit!,  :submitted)
  def approve = run_transition(:approve?, :approve!, :approved)

  def reject
    @expense = find_expense
    authorize @expense, :reject?
    result = approval.reject!(reason: params[:rejection_reason])
    transition_redirect(result, :rejected)
  end

  private

  def find_expense
    policy_scope(Expense).find(params[:id])
  end

  def approval
    Finance::ExpenseApproval.new(@expense, actor: current_user)
  end

  def run_transition(policy_method, service_method, flash_key)
    @expense = find_expense
    authorize @expense, policy_method
    result = approval.public_send(service_method)
    transition_redirect(result, flash_key)
  end

  def transition_redirect(result, flash_key)
    if result.ok?
      redirect_to finance_expense_path(@expense), notice: t("finance.expenses.#{flash_key}")
    else
      redirect_to finance_expense_path(@expense), alert: result.error
    end
  end

  def save_expense
    if @expense.expense_allocations.reject(&:marked_for_destruction?).any?
      Finance::AllocationCalculator.new(@expense, mode: allocation_mode).call
    end

    ActiveRecord::Base.transaction do
      if @expense.reference_number.blank?
        @expense.reference_number = Finance::NumberSequencer.new(current_user.business, :expense).next_number
      end
      @expense.save!
    end
    true
  rescue ActiveRecord::RecordInvalid
    false
  end

  def allocation_mode
    %w[equal percentage manual].include?(params[:allocation_mode]) ? params[:allocation_mode] : "percentage"
  end

  def load_options
    @categories  = current_user.business.expense_categories.active.ordered
    @types       = current_user.business.expense_types.active.ordered
    @tags        = current_user.business.expense_tags.active.ordered
    @hide_branch = hide_branch_selector?
    @branches    = @hide_branch ? [] : assignable_branches
  end

  def expense_params
    params.require(:expense).permit(
      :branch_id, :expense_category_id, :expense_type_id, :amount, :expense_date, :notes,
      :deduct_from_balance,
      expense_tag_ids: [], documents: [],
      expense_allocations_attributes: [ :id, :branch_id, :allocation_percentage, :allocated_amount, :_destroy ]
    )
  end
end
