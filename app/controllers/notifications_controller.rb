class NotificationsController < ApplicationController
  before_action :authenticate_user!

  EVENTS_PER_PAGE = 20

  def index
    authorize Notification
    @severity_filter = params[:severity].presence_in(Notification::SEVERITIES)
    @unread_only     = params[:unread] == "1"

    base = policy_scope(Notification).recent

    base = base.by_severity(@severity_filter) if @severity_filter
    base = base.unread                         if @unread_only

    @notifications    = base.limit(EVENTS_PER_PAGE)
    @unread_count     = policy_scope(Notification).unread.count
  end

  # PATCH /notifications/:id/mark_read
  def mark_read
    @notification = policy_scope(Notification).find(params[:id])
    authorize @notification, :update?
    @notification.mark_read!
    head :no_content
  end

  # PATCH /notifications/mark_all_read
  def mark_all_read
    authorize Notification
    Notification.mark_all_read_for!(current_user)
    redirect_to notifications_path, notice: t("notifications.all_marked_read")
  end
end
