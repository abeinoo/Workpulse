class Admin::BaseController < ApplicationController
  before_action :authenticate_user!
  before_action :require_admin_access!

  private

  def require_admin_access!
    unless current_user.can?(:manage_settings)    || current_user.can?(:manage_roles)    ||
           current_user.can?(:manage_devices)     || current_user.can?(:manage_obligations) ||
           current_user.can?(:manage_employees)   || current_user.can?(:manage_branches)  ||
           current_user.can?(:manage_shifts)      || current_user.can?(:manage_attendance) ||
           current_user.can?(:manage_salary_profiles) ||
           current_user.can?(:view_employees)     || current_user.can?(:view_attendance)  ||
           current_user.can?(:view_payroll)
      redirect_to root_path, alert: t("flash.not_authorized")
    end
  end
end
