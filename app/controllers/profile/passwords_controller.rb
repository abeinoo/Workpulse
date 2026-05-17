class Profile::PasswordsController < ApplicationController
  before_action :authenticate_user!

  def edit
    @user = current_user
  end

  def update
    @user = current_user

    if @user.update_with_password(password_params)
      # Re-authenticate to prevent Devise from signing the user out after
      # the password digest changes.
      bypass_sign_in(@user)

      UserAuditLog.create!(
        actor:       @user,
        target_user: @user,
        action:      "password_changed_self",
        ip_address:  request.remote_ip
      )

      redirect_to root_path, notice: t("flash.password_changed")
    else
      render :edit, status: :unprocessable_entity
    end
  end

  private

  def password_params
    params.require(:user).permit(:current_password, :password, :password_confirmation)
  end
end
