class Admin::SettingsController < Admin::BaseController
  def show
    @business = current_user.business
  end

  def update
    @business = current_user.business
    if @business.update(settings_params)
      redirect_to admin_settings_path, notice: t("flash.settings_updated")
    else
      render :show, status: :unprocessable_entity
    end
  end

  private

  def settings_params
    params.require(:business).permit(:timezone, :working_days_per_month, :business_day_start_hour, :default_locale, :max_late_permission_minutes, :max_early_leave_permission_minutes)
  end
end
