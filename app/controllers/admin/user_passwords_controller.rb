class Admin::UserPasswordsController < Admin::BaseController
  before_action :set_user

  def edit
    authorize @user, :reset_password?
  end

  def update
    authorize @user, :reset_password?

    if @user.update(password_params)
      UserAuditLog.create!(
        actor:       current_user,
        target_user: @user,
        action:      "password_reset_by_admin",
        ip_address:  request.remote_ip
      )

      redirect_to admin_user_path(@user), notice: t("flash.password_reset")
    else
      render :edit, status: :unprocessable_entity
    end
  end

  private

  def set_user
    @user = current_user.business.users.find(params[:user_id])
  end

  def password_params
    params.require(:user).permit(:password, :password_confirmation)
  end
end
