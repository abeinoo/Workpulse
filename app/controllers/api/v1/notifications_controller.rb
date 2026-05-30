module Api
  module V1
    # In-app notification feed for the mobile/SPA client. Every action is
    # scoped to the current user through NotificationPolicy::Scope, so a user
    # can only ever see or mutate their own notifications.
    class NotificationsController < BaseController
      PER_PAGE = 20

      # GET /api/v1/notifications
      # Optional filters: ?category= ?severity= ?unread=1 ?page=
      def index
        authorize Notification

        scope = policy_scope(Notification).recent
        scope = scope.by_category(category_param)   if category_param
        scope = scope.by_severity(severity_param)   if severity_param
        scope = scope.unread                        if params[:unread] == "1"

        page        = [ params[:page].to_i, 1 ].max
        total       = scope.count
        records     = scope.offset((page - 1) * PER_PAGE).limit(PER_PAGE)

        render_success({
          notifications: records.map { |n| notification_json(n) },
          meta: {
            page:         page,
            per_page:     PER_PAGE,
            total:        total,
            total_pages:  [ (total.to_f / PER_PAGE).ceil, 1 ].max,
            unread_count: policy_scope(Notification).unread.count
          }
        })
      end

      # GET /api/v1/notifications/unread_count
      def unread_count
        authorize Notification, :index?
        render_success({ unread_count: policy_scope(Notification).unread.count })
      end

      # PATCH /api/v1/notifications/:id/mark_read
      def mark_read
        notification = policy_scope(Notification).find(params[:id])
        authorize notification, :update?
        notification.mark_read!
        render_success(notification_json(notification))
      end

      # PATCH /api/v1/notifications/mark_all_read
      def mark_all_read
        authorize Notification, :index?
        Notification.mark_all_read_for!(current_user)
        render_success({ unread_count: 0 })
      end

      private

      def category_param
        params[:category].presence_in(Notification::CATEGORIES)
      end

      def severity_param
        params[:severity].presence_in(Notification::SEVERITIES)
      end

      def notification_json(n)
        {
          id:         n.id,
          event_type: n.event_type,
          category:   n.category,
          severity:   n.severity,
          title:      n.title,
          body:       n.body,
          data:       n.data,
          read:       n.read?,
          read_at:    n.read_at,
          created_at: n.created_at
        }
      end
    end
  end
end
