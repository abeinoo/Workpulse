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
      redirect_to admin_user_path(@employee), notice: t("flash.salary_profile_updated")
    else
      render :edit, status: :unprocessable_entity
    end
  end

  private

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
