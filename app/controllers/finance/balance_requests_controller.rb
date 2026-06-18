class Finance::BalanceRequestsController < Finance::BaseController
  before_action :require_balance_account!, only: %i[new create]

  def index
    authorize BalanceRequest
    @requests = policy_scope(BalanceRequest)
                  .with_status(params[:status])
                  .recent
                  .includes(:branch, :created_by, :approved_by)
  end

  def show
    @request    = find_request
    authorize @request
    @audit_logs = AuditLog.for_auditable(@request).recent
  end

  def new
    @request = current_user.business.balance_requests.build(request_date: Date.current)
    auto_assign_branch_from_balance_account(@request)
    authorize @request
    load_options
  end

  def create
    @request = current_user.business.balance_requests.build(request_params)
    @request.created_by = current_user
    auto_assign_branch_from_balance_account(@request)
    authorize @request

    if save_request
      redirect_to finance_balance_request_path(@request),
                  notice: t("finance.balance_requests.created")
    else
      load_options
      render :new, status: :unprocessable_entity
    end
  end

  def edit
    @request = find_request
    authorize @request, :update?
    load_options
  end

  def update
    @request = find_request
    authorize @request, :update?
    @request.assign_attributes(request_params)

    if save_request
      redirect_to finance_balance_request_path(@request),
                  notice: t("finance.balance_requests.updated")
    else
      load_options
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @request = find_request
    authorize @request, :destroy?
    @request.destroy
    redirect_to finance_balance_requests_path,
                notice: t("finance.balance_requests.deleted")
  end

  def submit    = run_transition(:submit?,    :submit!,    :submitted)
  def approve   = run_transition(:approve?,   :approve!,   :approved)
  def mark_paid = run_transition(:mark_paid?, :mark_paid!, :paid)

  def reject
    @request = find_request
    authorize @request, :reject?
    result = approval.reject!(reason: params[:rejection_reason])
    transition_redirect(result, :rejected)
  end

  def cancel
    @request = find_request
    authorize @request, :cancel?
    result = approval.cancel!(reason: params[:cancellation_reason])
    transition_redirect(result, :cancelled)
  end

  private

  def find_request
    policy_scope(BalanceRequest).find(params[:id])
  end

  def approval
    Finance::BalanceRequestApproval.new(@request, actor: current_user)
  end

  def run_transition(policy_method, service_method, flash_key)
    @request = find_request
    authorize @request, policy_method
    result = approval.public_send(service_method)
    transition_redirect(result, flash_key)
  end

  def transition_redirect(result, flash_key)
    target = safe_return_to || finance_balance_request_path(@request)
    if result.ok?
      redirect_to target, notice: t("finance.balance_requests.#{flash_key}")
    else
      redirect_to target, alert: result.error
    end
  end

  # Allow callers (e.g. custody account show page) to redirect back to themselves
  # after a transition. Only relative paths under /finance/custody_accounts are
  # trusted to prevent open-redirect (covers both index and show pages).
  def safe_return_to
    rt = params[:return_to].to_s
    rt if rt.start_with?("/finance/custody_accounts")
  end

  def save_request
    ActiveRecord::Base.transaction do
      if @request.reference_number.blank?
        @request.reference_number =
          Finance::NumberSequencer.new(current_user.business, :balance_request).next_number
      end
      @request.save!
    end
    true
  rescue ActiveRecord::RecordInvalid
    false
  end

  def load_options
    @hide_branch = hide_branch_selector?
    @branches    = @hide_branch ? [] : assignable_branches
  end

  def request_params
    params.require(:balance_request).permit(
      :branch_id, :amount, :request_date, :notes
    )
  end
end
