# Manages the standard laundry-service cost for a SINGLE towel type — nested
# under Towel Types (see Laundry::TowelTypesController), not a standalone
# module. An append-only rate history per towel type
# (Laundry::StandardCostRateSetter never edits/deletes existing rows); the
# towel type itself is always known from the route, never re-selected here.
class Laundry::StandardCostRatesController < Laundry::BaseController
  before_action :set_towel_type

  def new
    @rate = LaundryStandardCostRate.new(towel_type: @towel_type)
    authorize @rate
    load_history
  end

  def create
    authorize LaundryStandardCostRate

    result = Laundry::StandardCostRateSetter.call(
      actor: current_user, towel_type: @towel_type, cost_per_towel: rate_params[:cost_per_towel],
      effective_from: rate_params[:effective_from].presence || Time.current
    )

    if result.ok?
      redirect_to laundry_towel_types_path, notice: t("laundry.standard_cost_rates.created")
    else
      @rate = result.rate
      load_history
      flash.now[:alert] = result.error
      render :new, status: :unprocessable_entity
    end
  end

  private

  def set_towel_type
    @towel_type = policy_scope(TowelType).find(params[:towel_type_id])
  end

  def load_history
    @rates = policy_scope(LaundryStandardCostRate).for_towel_type(@towel_type).chronological.reverse_order
    @current_rate = LaundryStandardCostRate.effective_for(current_user.business, towel_type: @towel_type, at: Time.current)
  end

  def rate_params
    params.require(:laundry_standard_cost_rate).permit(:cost_per_towel, :effective_from)
  end
end
