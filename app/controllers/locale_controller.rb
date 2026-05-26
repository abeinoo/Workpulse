class LocaleController < ApplicationController
  skip_before_action :authenticate_user!, raise: false
  # allow unauthenticated visitors to set their display language

  def update
    locale = params[:locale].to_s
    if I18n.available_locales.map(&:to_s).include?(locale)
      session[:locale] = locale
      # Also persist to user preference if signed in
      current_user.update_column(:preferred_locale, locale) if user_signed_in?
    end

    respond_to do |format|
      format.json { head :ok }
      format.html { redirect_back(fallback_location: new_user_session_path) }
    end
  end
end
