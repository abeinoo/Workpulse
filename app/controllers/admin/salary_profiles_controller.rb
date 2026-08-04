class Admin::SalaryProfilesController < Admin::BaseController
  before_action :set_employee
  before_action :set_profile, only: [ :edit, :update ]

  def new
    @profile = @employee.salary_profiles.new(currency: @employee.business.currency, active: true)
    authorize @profile
  end

  def create
    @profile = @employee.salary_profiles.new(profile_params.merge(currency: @employee.business.currency, active: true))
    authorize @profile

    if @profile.save
      recalculate_open_periods
      redirect_to admin_user_path(@employee), notice: t("flash.salary_profile_created")
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
    authorize @profile
  end

  def update
    authorize @profile

    if @profile.update(profile_params)
      recalculate_open_periods
      redirect_to admin_user_path(@employee), notice: t("flash.salary_profile_updated")
    else
      render :edit, status: :unprocessable_entity
    end
  end

  private

  # A salary profile change should be reflected in every currently editable
  # period, not just the next full generation. Never allowed to fail the
  # salary profile change itself.
  def recalculate_open_periods
    Payroll::EntryRecalculator.recalculate_all_open_periods_for(user: @employee, triggered_by: current_user)
  rescue => e
    Rails.logger.error("[Admin::SalaryProfilesController] payroll recalc failed user=#{@employee.id}: #{e.class}: #{e.message}")
  end

  def set_employee
    @employee = current_user.business.users.find(params[:user_id])
  end

  def set_profile
    @profile = policy_scope(SalaryProfile)
                 .where(user: @employee)
                 .find(params[:id])
  end

  def profile_params
    params.require(:salary_profile).permit(
      :salary_type, :base_amount, :overtime_multiplier, :effective_from
    )
  end

  def require_admin_access!
    unless current_user.can?(:manage_salary_profiles)
      redirect_to root_path, alert: t("flash.not_authorized")
    end
  end
end
