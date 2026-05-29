module Payroll
  # Central notification router for payroll workflow events.
  # Creates in-app Notification records and provides hooks for future
  # email / WhatsApp channels.
  #
  # Usage:
  #   Payroll::NotificationService.notify(
  #     event:  :finalized,
  #     period: @period,
  #     actor:  current_user
  #   )
  class NotificationService
    EVENTS = %i[
      submitted_for_review
      branch_review_completed
      finalized
      paid
      regenerated
      adjustment_approved
      adjustment_rejected
    ].freeze

    EVENT_TO_NOTIFICATION_TYPE = {
      submitted_for_review:    "payroll_submitted",
      branch_review_completed: "payroll_submitted",
      finalized:               "payroll_finalized",
      paid:                    "payroll_paid",
      regenerated:             "payroll_regenerated",
      adjustment_approved:     "adjustment_approved",
      adjustment_rejected:     "adjustment_rejected"
    }.freeze

    EVENT_SEVERITY = {
      submitted_for_review:    "info",
      branch_review_completed: "info",
      finalized:               "success",
      paid:                    "success",
      regenerated:             "warning",
      adjustment_approved:     "success",
      adjustment_rejected:     "warning"
    }.freeze

    def self.notify(event:, period:, actor:, **context)
      new(event: event, period: period, actor: actor, context: context).deliver
    end

    def initialize(event:, period:, actor:, context: {})
      @event   = event.to_sym
      @period  = period
      @actor   = actor
      @context = context
    end

    def deliver
      return false unless EVENTS.include?(@event)

      # ── In-app notifications ────────────────────────────────────────────
      deliver_in_app

      # ── Email channel (future) ──────────────────────────────────────────
      # PayrollMailer.workflow_event(@event, @period, @actor).deliver_later

      # ── WhatsApp / SMS channel (future) ────────────────────────────────
      # WhatsAppNotifier.new(@event, @period, @actor, @context).deliver

      true
    end

    private

    def deliver_in_app
      recipients.each do |user|
        Notification.create!(
          user:       user,
          notifiable: @period,
          event_type: EVENT_TO_NOTIFICATION_TYPE.fetch(@event, "system_warning"),
          title:      notification_title,
          body:       notification_body,
          severity:   EVENT_SEVERITY.fetch(@event, "info")
        )
      rescue ActiveRecord::RecordInvalid => e
        Rails.logger.warn("[NotificationService] Failed to create notification for user=#{user.id} event=#{@event}: #{e.message}")
      end
    end

    def notification_title
      I18n.t("notifications.payroll.#{@event}.title",
             label:  @period.period_label,
             actor:  actor_name,
             default: @period.period_label)
    end

    def notification_body
      I18n.t("notifications.payroll.#{@event}.body",
             label:  @period.period_label,
             actor:  actor_name,
             default: "")
    end

    def actor_name
      "#{@actor.first_name} #{@actor.last_name}".strip
    end

    # Who gets notified depends on the event:
    # - finalized/paid  → all users with view_payroll in the business
    # - submitted       → owner
    # - adjustment      → the affected employee (stored in context[:user])
    def recipients
      business = @period.business

      case @event
      when :finalized, :paid
        business.users.where(active: true).select { |u|
          u.can?(:view_payroll)
        }
      when :submitted_for_review, :branch_review_completed, :regenerated
        business.users.where(active: true).select { |u| u.can?(:view_payroll) }
      when :adjustment_approved, :adjustment_rejected
        [ @context[:user] ].compact
      else
        business.users.where(active: true).select { |u| u.can?(:view_payroll) }
      end
    rescue => e
      Rails.logger.warn("[NotificationService] Failed to resolve recipients for event=#{@event}: #{e.message}")
      []
    end
  end
end
