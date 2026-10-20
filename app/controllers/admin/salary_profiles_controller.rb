class Admin::SalaryProfilesController < Admin::BaseController
  before_action :set_employee
  before_action :set_profile, only: [ :edit, :update ]

  # Standalone records (never built into @employee.salary_profiles).
  def new
    @profile = SalaryProfile.new(user_id: @employee.id, currency: @employee.business.currency, active: true)
    authorize @profile
  end

  def create
    authorize SalaryProfile.new(user_id: @employee.id)
    result = Salary::ProfileUpdater.call(user: @employee, actor: current_user, source: "admin",
                                         params: profile_params.merge(currency: @employee.business.currency))

    if result.success?
      redirect_to admin_user_path(@employee), notice: t("flash.salary_profile_created")
    else
      @profile = result.profile
      render :new, status: :unprocessable_entity
    end
  end

  def edit
    authorize @profile
    Salary::ViewAudit.record(actor: current_user, employee: @employee, profiles: [ @profile ],
                             source: "admin_salary_profile_edit")
  end

  def update
    authorize @profile
    result = Salary::ProfileCorrector.call(profile_id: @profile.id, attributes: profile_params,
                                           actor: current_user, source: "admin")

    if result.success?
      redirect_to admin_user_path(@employee), notice: t("flash.salary_profile_updated")
    else
      @profile = result.profile
      render :edit, status: :unprocessable_entity
    end
  end

  private

  # Only employees whose salary the actor may manage — never the actor
  # (SEC-M2-6); anyone else is not found.
  def set_employee
    @employee = SalaryProfilePolicy.manageable_employees(current_user).find(params[:user_id])
  end

  def set_profile
    @profile = @employee.salary_profiles.find(params[:id])
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
