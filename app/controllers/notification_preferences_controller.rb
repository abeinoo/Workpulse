class NotificationPreferencesController < ApplicationController
  before_action :authenticate_user!

  # GET /notification_preferences
  def show
    @preferences = Notification::CATEGORIES.index_with do |cat|
      current_user.notification_enabled?(cat)
    end
  end

  # PATCH /notification_preferences
  # Expects params[:categories] => { "attendance" => "1"/"0", ... }.
  # An unchecked checkbox submits nothing, so a category absent from the params
  # is treated as disabled.
  def update
    submitted = params.fetch(:categories, {})
    prefs = Notification::CATEGORIES.index_with do |cat|
      ActiveModel::Type::Boolean.new.cast(submitted[cat])
    end
    current_user.update!(notification_preferences: prefs)
    redirect_to notification_preferences_path, notice: t("notifications.preferences.saved")
  end
end
