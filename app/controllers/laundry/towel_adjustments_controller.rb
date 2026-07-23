class Laundry::TowelAdjustmentsController < Laundry::BaseController
  def index
    authorize TowelAdjustment
    @towel_adjustments = policy_scope(TowelAdjustment)
                          .order(created_at: :desc)
                          .includes(:towel_type, :branch, :created_by)
  end

  def new
    @towel_adjustment = current_user.business.towel_adjustments.build
    authorize @towel_adjustment
    load_options
  end

  def create
    adj_params = params.require(:towel_adjustment).permit(:branch_id, :towel_type_id, :adjustment_type,
                                                           :status, :adjustment_quantity, :quantity, :reason)
    branch = current_user.business.branches.find(adj_params[:branch_id])
    towel_type = current_user.business.towel_types.find(adj_params[:towel_type_id])
    adjustment_type = adj_params[:adjustment_type].presence || "correction"

    # Build for authorization + as the form fallback on failure — the actual
    # persisted (or invalid, unsaved) record always comes from the service.
    @towel_adjustment = current_user.business.towel_adjustments.build(
      branch: branch, towel_type: towel_type, adjustment_type: adjustment_type,
      status: adj_params[:status], adjustment_quantity: adj_params[:adjustment_quantity],
      reason: adj_params[:reason]
    )
    authorize @towel_adjustment

    result =
      if adjustment_type.in?(%w[lost damaged])
        Laundry::TowelAdjuster.new(actor: current_user).record_loss(
          towel_type: towel_type, branch: branch, adjustment_type: adjustment_type,
          quantity: adj_params[:quantity], reason: adj_params[:reason]
        )
      else
        Laundry::TowelAdjuster.new(actor: current_user).call(
          towel_type: towel_type, branch: branch, status: adj_params[:status],
          adjustment_quantity: adj_params[:adjustment_quantity], reason: adj_params[:reason]
        )
      end
    @towel_adjustment = result.adjustment if result.adjustment

    if result.ok?
      redirect_to laundry_towel_adjustments_path, notice: t("laundry.adjustments.created")
    else
      load_options
      flash.now[:alert] = result.error
      render :new, status: :unprocessable_entity
    end
  end

  private

  def load_options
    @branches = assignable_branches(:adjust_towel_balances, :view_towel_balances)
    @towel_types = laundry_towel_types
    @statuses = TowelLedgerEntry::STATUSES
  end
end
