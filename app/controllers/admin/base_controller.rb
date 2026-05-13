class Admin::BaseController < ApplicationController
  before_action :authenticate_user!
  before_action :require_super_admin!

  private

  def require_super_admin!
    redirect_to root_path, alert: "Not authorized." unless current_user.super_admin?
  end
end
