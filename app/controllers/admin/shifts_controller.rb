class Admin::ShiftsController < Admin::BaseController
  def index
    @shifts = Shift.where(business_id: current_user.business_id).order(:name)
  end

  def show
    @shift = find_shift
    @penalty_rules = @shift.penalty_rules.order(:threshold_minutes)
  end

  def new
    @shift = current_user.business.shifts.build
  end

  def create
    @shift = current_user.business.shifts.build(shift_params)
    if @shift.save
      redirect_to admin_shifts_path, notice: t("flash.shift_created")
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
    @shift = find_shift
  end

  def update
    @shift = find_shift
    if @shift.update(shift_params)
      redirect_to admin_shifts_path, notice: t("flash.shift_updated")
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    find_shift.destroy
    redirect_to admin_shifts_path, notice: t("flash.shift_removed")
  end

  private

  def find_shift
    Shift.where(business_id: current_user.business_id).find(params[:id])
  end

  def shift_params
    params.require(:shift).permit(
      :name, :shift_type, :start_time, :end_time, :required_hours, :overtime_rate_multiplier,
      penalty_rules_attributes: [ :id, :rule_type, :threshold_minutes, :deduction_type, :deduction_value, :_destroy ]
    )
  end
end
