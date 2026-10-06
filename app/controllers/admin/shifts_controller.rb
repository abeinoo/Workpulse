class Admin::ShiftsController < Admin::BaseController
  # Every action authorizes with ShiftPolicy (SEC-M2-9): Admin::BaseController's
  # gate admits view_employees, view_payroll …, and shift_params also writes
  # penalty_rules_attributes, so changes require manage_shifts. The index keeps
  # its own query (ShiftPolicy::Scope would hide inactive shifts).
  def index
    authorize Shift
    @shifts = Shift.where(business_id: current_user.business_id).order(:name)
  end

  def show
    @shift = find_shift
    authorize @shift
    @penalty_rules = @shift.penalty_rules.order(:threshold_minutes)
  end

  def new
    @shift = current_user.business.shifts.build
    authorize @shift
  end

  def create
    @shift = current_user.business.shifts.build(shift_params)
    authorize @shift
    if @shift.save
      redirect_to admin_shifts_path, notice: t("flash.shift_created")
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
    @shift = find_shift
    authorize @shift
  end

  def update
    @shift = find_shift
    authorize @shift
    if @shift.update(shift_params)
      redirect_to admin_shifts_path, notice: t("flash.shift_updated")
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @shift = find_shift
    authorize @shift
    @shift.destroy
    redirect_to admin_shifts_path, notice: t("flash.shift_removed")
  end

  private

  def find_shift
    Shift.where(business_id: current_user.business_id).find(params[:id])
  end

  def shift_params
    params.require(:shift).permit(
      :name, :shift_type, :start_time, :end_time, :required_hours, :overtime_rate_multiplier,
      :max_late_permission_minutes, :max_early_leave_permission_minutes,
      penalty_rules_attributes: [ :id, :rule_type, :threshold_minutes, :deduction_type, :deduction_value, :_destroy ]
    )
  end
end
