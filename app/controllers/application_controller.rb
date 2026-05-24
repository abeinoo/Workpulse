class ApplicationController < ActionController::Base
  include Pundit::Authorization

  allow_browser versions: :modern
  stale_when_importmap_changes

  before_action :set_locale
  before_action :configure_permitted_parameters, if: :devise_controller?
  before_action :ensure_active_user, if: :user_signed_in?

  rescue_from Pundit::NotAuthorizedError, with: :handle_pundit_unauthorized

  protected

  def set_locale
    # Priority: 1) user preference  2) session (set immediately on switch)
    #           3) business default  4) app default
    locale = if user_signed_in?
      current_user.preferred_locale.presence ||
        session[:locale].presence ||
        current_user.business.default_locale.presence ||
        I18n.default_locale
    else
      session[:locale].presence || I18n.default_locale
    end

    # Guard against invalid values that could sneak in via a stale session.
    locale = I18n.default_locale unless I18n.available_locales.map(&:to_s).include?(locale.to_s)

    I18n.locale = locale.to_sym
  end

  def configure_permitted_parameters
    devise_parameter_sanitizer.permit(:sign_in, keys: [:login])
  end

  def ensure_active_user
    return if current_user.active?
    sign_out current_user
    redirect_to new_user_session_path, alert: t("devise.failure.inactive")
  end

  def after_sign_in_path_for(resource)
    resource.owner? ? admin_root_path : root_path
  end

  def handle_pundit_unauthorized
    redirect_to root_path, alert: t("flash.not_authorized")
  end
end
