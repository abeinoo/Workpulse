class Admin::BaseController < ApplicationController
  before_action :authenticate_user!
  before_action :require_admin_access!

  private

  def require_admin_access!
    unless current_user.owner? || current_user.permission_role.present?
      redirect_to root_path, alert: t("flash.not_authorized")
    end
  end
end
