class PreferencesController < ApplicationController
  before_action :authenticate_user!

  def update
    locale = params[:locale].to_s
    if I18n.available_locales.map(&:to_s).include?(locale)
      current_user.update_column(:preferred_locale, locale)
      # Mirror to session so the very next request sees the new locale
      # even before the memoised current_user is refreshed.
      session[:locale] = locale
    end

    respond_to do |format|
      format.json { head :ok }
      format.html { redirect_back(fallback_location: root_path) }
    end
  end
end
