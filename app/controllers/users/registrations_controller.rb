class Users::RegistrationsController < Devise::RegistrationsController
  # Account activation requires the administrator-issued invitation link
  # (?invitation=<token>); see Users::RegistrationService (OA-S6).
  def new
    build_resource({})
    @invitation_token = params[:invitation].to_s
    render :new
  end

  def create
    result = Users::RegistrationService.call(
      login:                 sign_up_params[:login],
      password:              sign_up_params[:password],
      password_confirmation: sign_up_params[:password_confirmation],
      invitation_token:      sign_up_params[:invitation_token]
    )

    if result.success?
      sign_in(result.user)
      redirect_to root_path, notice: t("flash.welcome_registered")
    else
      build_resource(login: sign_up_params[:login])
      @invitation_token = sign_up_params[:invitation_token].to_s
      resource.errors.add(:base, result.error)
      render :new, status: :unprocessable_entity
    end
  end

  private

  def sign_up_params
    params.require(:user).permit(:login, :password, :password_confirmation, :invitation_token)
  end
end
