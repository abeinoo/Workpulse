class Finance::DailyReconciliationsController < Finance::BaseController
  before_action :set_reconciliation, only: %i[show verify]

  # GET /finance/daily_reconciliations
  def index
    authorize DailyReconciliation
    @reconciliations = policy_scope(DailyReconciliation)
                         .includes(:branch, :verified_by)
                         .ordered
  end

  # GET /finance/daily_reconciliations/:id
  def show
    authorize @reconciliation
    @handover_chain  = @reconciliation.handover_chain
    @by_method       = @reconciliation.collected_by_method
    @total_deposited = @reconciliation.total_deposited
  end

  # PATCH /finance/daily_reconciliations/:id/verify
  def verify
    authorize @reconciliation, :verify?

    result = Finance::DailyReconciliationVerifier.new(
      branch:        @reconciliation.branch,
      business_date: @reconciliation.business_date,
      actor:         current_user,
      notes:         params[:notes]
    ).call

    if result.ok?
      redirect_to finance_daily_reconciliation_path(result.reconciliation),
                  notice: t("finance.daily_reconciliations.verified")
    else
      redirect_to finance_daily_reconciliation_path(@reconciliation),
                  alert: result.error
    end
  end

  private

  def set_reconciliation
    @reconciliation = policy_scope(DailyReconciliation).find(params[:id])
  end
end
