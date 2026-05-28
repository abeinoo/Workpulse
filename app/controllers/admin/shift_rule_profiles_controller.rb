class Admin::ShiftRuleProfilesController < Admin::BaseController
  def index
    authorize ShiftRuleProfile, :index?
    @profiles = policy_scope(ShiftRuleProfile)
                  .order(:name)
  end

  def show
    @profile = find_profile
    authorize @profile
  end

  def new
    @profile = ShiftRuleProfile.new(overtime_enabled: true)
    authorize @profile
  end

  def create
    @profile          = ShiftRuleProfile.new(profile_params)
    @profile.business = current_user.business
    authorize @profile

    if @profile.save
      redirect_to admin_shift_rule_profile_path(@profile),
                  notice: t("flash.shift_rule_profile_created")
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
    @profile = find_profile
    authorize @profile
  end

  def update
    @profile = find_profile
    authorize @profile

    if @profile.update(profile_params)
      redirect_to admin_shift_rule_profile_path(@profile),
                  notice: t("flash.shift_rule_profile_updated")
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @profile = find_profile
    authorize @profile

    if @profile.shift_assignments.exists? || @profile.shift_template_entries.exists?
      redirect_to admin_shift_rule_profiles_path,
                  alert: t("shift_rule_profiles.destroy.in_use")
    else
      @profile.destroy!
      redirect_to admin_shift_rule_profiles_path,
                  notice: t("flash.shift_rule_profile_deleted")
    end
  end

  private

  def find_profile
    policy_scope(ShiftRuleProfile).find(params[:id])
  end

  def profile_params
    params.require(:shift_rule_profile).permit(
      :name, :description,
      :expected_work_hours, :break_minutes,
      :late_grace_minutes, :early_leave_grace_minutes,
      :overtime_enabled, :overtime_multiplier,
      :active
    )
  end
end
