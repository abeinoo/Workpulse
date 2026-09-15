class Finance::ExpensesController < Finance::BaseController
  helper_method :index_filter_params

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
    @paid_amounts = FinancialSettlement.where(settleable_type: "Expense", settleable_id: @expenses.map(&:id))
                                        .group(:settleable_id).sum(:amount)
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
    @settlements = @expense.financial_settlements.chronological.includes(:funding_source, :created_by)
  end

  def new
    @expense = current_user.business.expenses.build(expense_date: Date.current)
    auto_assign_expense_branch(@expense)
    authorize @expense
    load_options
  end

  def create
    @expense = current_user.business.expenses.build(expense_params)
    @expense.created_by = current_user
    auto_assign_expense_branch(@expense)
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

  def cancel
    @expense = find_expense
    authorize @expense, :cancel?
    result = approval.cancel!(reason: params[:cancellation_reason])
    transition_redirect(result, :cancelled)
  end

  private

  INDEX_FILTER_PARAMS = %i[status branch_id expense_category_id expense_type_id created_by_id from to].freeze

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
    target = params[:from_index].present? ? finance_expenses_path(index_filter_params) : finance_expense_path(@expense)

    if result.ok?
      redirect_to target, notice: t("finance.expenses.#{flash_key}")
    else
      redirect_to target, alert: result.error
    end
  end

  def index_filter_params
    params.permit(*INDEX_FILTER_PARAMS).to_h.compact_blank
  end

  def save_expense
    if @expense.branch_id.blank? && @expense.expense_allocations.reject(&:marked_for_destruction?).any?
      Finance::AllocationCalculator.new(@expense, mode: @expense.distribution_method || "percentage").call
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

  def load_options
    @categories          = current_user.business.expense_categories.active.ordered
    @types               = current_user.business.expense_types.active.ordered
    @tags                = current_user.business.expense_tags.active.ordered
    @hide_branch         = hide_expense_branch_selector?
    @branches            = @hide_branch ? [] : assignable_expense_branches
    @show_shared_section = expense_branch_scope == "business"
    # "Paid from my balance/custody" is an OPTIONAL, independent choice — see
    # Expense model comment. It's only ever shown when an eligible account
    # actually exists; otherwise the whole control is hidden (never a
    # disabled checkbox or a validation nag). Checking it auto-settles from
    # the CREATOR's own custody account at approval (unchanged
    # Finance::ExpenseApproval mechanism) — not necessarily current_user's,
    # since a manager may be editing someone else's draft — so the preview
    # must reflect whichever account will actually be debited.
    account_owner = @expense.created_by || current_user
    @eligible_custody_account =
      CustodyAccount.where(business: current_user.business, user: account_owner, active: true).first
  end

  # The branch <select> submits the literal string "shared" for the
  # Shared (Organization Level) option — translate it to a nil branch_id,
  # which is what the model treats as "shared" throughout.
  def expense_params
    permitted = params.require(:expense).permit(
      :branch_id, :expense_category_id, :expense_type_id, :amount, :expense_date, :notes,
      :payment_type, :deduct_from_balance, :distribution_method,
      expense_tag_ids: [], documents: [],
      expense_allocations_attributes: [ :id, :branch_id, :allocation_percentage, :allocated_amount, :_destroy ]
    )
    permitted[:branch_id] = nil if permitted[:branch_id] == "shared"
    permitted
  end
end
