class Users::RegistrationsController < Devise::RegistrationsController
  # Self-service activation of a pending account by its registered mobile
  # number (Users::RegistrationService; phone-only is an accepted risk, see
  # OA-S6). Only the phone number and the password pair are read from the
  # request — never a business, branch, role or any other attribute.

  # Guessing protection, as on the API login (same store, so the counters
  # follow Rails.cache): per IP and phone number (hashed, so no number lands in
  # cache keys; equivalent formats share one bucket), and a looser per-IP cap
  # against sweeping many numbers from one address.
  rate_limit to: 5, within: 15.minutes, only: :create, name: "registration-phone",
             by:    :registration_rate_limit_key,
             with:  -> { render_registration_rate_limited },
             store: Api::RateLimitStore
  rate_limit to: 20, within: 15.minutes, only: :create, name: "registration-ip",
             with:  -> { render_registration_rate_limited },
             store: Api::RateLimitStore

  def create
    result = Users::RegistrationService.call(
      phone_number:          sign_up_params[:phone_number],
      password:              sign_up_params[:password],
      password_confirmation: sign_up_params[:password_confirmation],
      ip_address:            request.remote_ip
    )

    if result.success?
      sign_in(result.user)
      redirect_to root_path, notice: t("flash.welcome_registered")
    else
      render_form_with_error(result.error, status: :unprocessable_entity)
    end
  end

  private

  def sign_up_params
    params.require(:user).permit(:phone_number, :password, :password_confirmation)
  end

  # The typed number is redisplayed as typed (not through the model's phone
  # normalization, which would drop e.g. Arabic-Indic digits).
  def render_form_with_error(message, status:)
    build_resource({})
    resource.errors.add(:base, message)
    @phone_number = submitted_phone_number
    render :new, status: status
  end

  def render_registration_rate_limited
    render_form_with_error(t("auth.register.rate_limited"), status: :too_many_requests)
  end

  def submitted_phone_number
    user_params = params[:user]
    (user_params.respond_to?(:key?) ? user_params[:phone_number] : nil).to_s.strip
  end

  def registration_rate_limit_key
    phone = submitted_phone_number
    phone = PhoneNumber.comparison_key(phone) || phone.downcase
    "#{request.remote_ip}:#{Digest::SHA256.hexdigest(phone)}"
  end
end
