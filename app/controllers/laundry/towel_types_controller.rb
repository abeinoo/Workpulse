class Laundry::TowelTypesController < Laundry::BaseController
  before_action :set_towel_type, only: %i[edit update destroy]

  def index
    authorize TowelType
    @towel_types = policy_scope(TowelType).order(:name)

    # Cost visibility/management is gated separately from Towel Types
    # visibility (see LaundryStandardCostRatePolicy) — a normal laundry
    # worker with only view_towel_balances must not see cost figures merely
    # because they can reach this page.
    @can_view_cost   = policy(LaundryStandardCostRate).index?
    @can_manage_cost = policy(LaundryStandardCostRate).new?
    if @can_view_cost
      @current_rates = LaundryStandardCostRate.current_by_towel_type(current_user.business, @towel_types.map(&:id))
    end
  end

  def new
    @towel_type = current_user.business.towel_types.build(active: true)
    authorize @towel_type
  end

  def create
    @towel_type = current_user.business.towel_types.build(towel_type_params)
    authorize @towel_type
    if @towel_type.save
      redirect_to laundry_towel_types_path, notice: t("laundry.towel_types.created")
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
    authorize @towel_type
  end

  def update
    authorize @towel_type
    if @towel_type.update(towel_type_params)
      redirect_to laundry_towel_types_path, notice: t("laundry.towel_types.updated")
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    authorize @towel_type
    if @towel_type.destroy
      redirect_to laundry_towel_types_path, notice: t("laundry.towel_types.deleted")
    else
      redirect_to laundry_towel_types_path,
                  alert: @towel_type.errors.full_messages.to_sentence.presence || t("laundry.towel_types.delete_failed")
    end
  end

  private

  def set_towel_type
    @towel_type = policy_scope(TowelType).find(params[:id])
  end

  def towel_type_params
    params.require(:towel_type).permit(:name, :active)
  end
end
