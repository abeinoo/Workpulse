class Users::RegistrationsController < Devise::RegistrationsController
  def new
    build_resource({})
    render :new
  end

  def create
    result = Users::RegistrationService.call(
      login:                 sign_up_params[:login],
      password:              sign_up_params[:password],
      password_confirmation: sign_up_params[:password_confirmation]
    )

    if result.success?
      sign_in(result.user)
      redirect_to root_path, notice: "Welcome! You have registered successfully."
    else
      build_resource({})
      resource.errors.add(:base, result.error)
      render :new, status: :unprocessable_entity
    end
  end

  private

  def sign_up_params
    params.require(:user).permit(:login, :password, :password_confirmation)
  end
end
