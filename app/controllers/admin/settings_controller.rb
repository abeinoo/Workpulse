class Admin::SettingsController < Admin::BaseController
  before_action :require_settings_access!

  def show
    @business = current_user.business
  end

  def update
    @business = current_user.business

    p = settings_params
    removals = p.extract!(:remove_logo, :remove_stamp_image)

    if @business.update(p)
      %i[logo stamp_image].each do |name|
        @business.public_send(name).purge if removals["remove_#{name}"] == "1"
      end
      redirect_to admin_settings_path, notice: t("flash.settings_updated")
    else
      render :show, status: :unprocessable_entity
    end
  end

  private

  def require_settings_access!
    redirect_to root_path, alert: t("flash.not_authorized") unless current_user.can?(:manage_settings)
  end

  def settings_params
    params.require(:business).permit(
      :timezone, :working_days_per_month, :business_day_start_hour,
      :default_locale, :currency, :max_salary_advance_percentage,
      :overtime_grace_minutes,
      :payroll_auto_generate_day, :payroll_cutoff_day,
      :employee_code_start,
      :barcode_prefix, :barcode_next_number,
      :logo, :stamp_image,
      :remove_logo, :remove_stamp_image,
      :finance_overdue_days, :finance_allow_partial_settlement,
      :finance_max_write_off_amount, :finance_notify_thresholds
    )
  end
end
