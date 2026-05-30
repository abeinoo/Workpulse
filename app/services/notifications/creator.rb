module Notifications
  # Single entry point for creating in-app notifications.
  #
  # Responsibilities:
  #   1. Resolve category + severity from the event catalog (callers only need
  #      to pass an event_type — keeps presentation consistent everywhere).
  #   2. Respect the recipient's per-category notification preferences.
  #   3. De-duplicate: optionally skip if an equivalent unread notification was
  #      created within a recent window (prevents reminder spam).
  #   4. Persist the Notification (the model's after_commit hook refreshes the
  #      cached unread badge count).
  #
  # The service is channel-agnostic: today it writes in-app rows, but the
  # `deliver_extra_channels` hook is where email / push / SMS fan-out will go.
  #
  # Usage:
  #   Notifications::Creator.call(
  #     user:       employee,
  #     event_type: "leave_approved",
  #     title:      "Your leave was approved",
  #     body:       "...",
  #     notifiable: request,
  #     dedup_within: 12.hours
  #   )
  #
  # Returns the created Notification, or nil when skipped (preference off,
  # deduped, or invalid).
  class Creator
    def self.call(**kwargs)
      new(**kwargs).call
    end

    # Convenience: create the same notification for many recipients.
    # Returns the array of created (non-nil) Notifications.
    def self.broadcast(users:, **kwargs)
      Array(users).filter_map { |u| call(user: u, **kwargs) }
    end

    def initialize(user:, event_type:, title:, body: nil, notifiable: nil,
                   severity: nil, category: nil, data: {}, dedup_within: nil)
      @user         = user
      @event_type   = event_type.to_s
      @title        = title
      @body         = body
      @notifiable   = notifiable
      @severity     = severity || Notification.severity_for(@event_type)
      @category     = category || Notification.category_for(@event_type)
      @data         = data || {}
      @dedup_within = dedup_within
    end

    def call
      return nil unless @user
      return nil unless Notification::EVENT_TYPES.include?(@event_type)
      return nil unless preference_allows?
      return nil if duplicate_exists?

      notification = Notification.new(
        user:       @user,
        notifiable: @notifiable,
        event_type: @event_type,
        category:   @category,
        title:      @title,
        body:       @body,
        severity:   @severity,
        data:       @data
      )

      if notification.save
        deliver_extra_channels(notification)
        notification
      else
        Rails.logger.warn(
          "[Notifications::Creator] invalid event=#{@event_type} user=#{@user.id}: " \
          "#{notification.errors.full_messages.join(', ')}"
        )
        nil
      end
    end

    private

    def preference_allows?
      return true if @category.blank?

      @user.notification_enabled?(@category)
    end

    # Dedup is opt-in. When a window is supplied we suppress a new notification
    # if the same recipient already has one for the same event + notifiable
    # created within that window (read or unread — avoids re-pinging on reruns).
    def duplicate_exists?
      return false unless @dedup_within

      scope = Notification
                .where(user: @user, event_type: @event_type)
                .where("created_at > ?", @dedup_within.ago)
      scope = scope.where(notifiable: @notifiable) if @notifiable
      scope.exists?
    end

    # Hook for future channels. Each is independently fail-safe so a downstream
    # outage never blocks the in-app notification.
    def deliver_extra_channels(_notification)
      # NotificationMailer.event(notification).deliver_later  if email_enabled?
      # PushDispatcher.deliver(notification)                  if push_enabled?
      nil
    end
  end
end
