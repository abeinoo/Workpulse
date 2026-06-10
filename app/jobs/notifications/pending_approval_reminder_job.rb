module Notifications
  # Reminds reviewers when employee requests have been sitting in the pending
  # state. Groups pending requests by reviewer and sends one summary reminder
  # per reviewer (not one per request) to avoid noise.
  #
  # A request is considered "stale" once it is older than STALE_AFTER. The
  # Creator dedup window prevents re-pinging the same reviewer within a day.
  class PendingApprovalReminderJob < ApplicationJob
    queue_as :background

    STALE_AFTER = 12.hours

    def perform
      Business.find_each do |business|
        process_business(business)
      rescue StandardError => e
        Rails.logger.error("[PendingApprovalReminderJob] business=#{business.id}: #{e.class}: #{e.message}")
      end
    end

    private

    def process_business(business)
      pending = EmployeeRequest
                  .joins(:user)
                  .where(users: { business_id: business.id })
                  .where(status: "pending")
                  .where("employee_requests.created_at < ?", STALE_AFTER.ago)
                  .includes(:user)
      return if pending.empty?

      # Map each reviewer → count of pending requests they're responsible for.
      counts = Hash.new(0)
      pending.each do |req|
        reviewers_for(req).each { |reviewer| counts[reviewer] += 1 }
      end

      counts.each do |reviewer, count|
        Notifications::Creator.call(
          user:         reviewer,
          event_type:   "manager_pending_approvals",
          title:        I18n.t("notifications.requests.pending_reminder.title", count: count),
          body:         I18n.t("notifications.requests.pending_reminder.body", count: count),
          data:         { pending_count: count },
          dedup_within: 20.hours
        )
      end
    end

    # Who to remind about a stale request: the requester's branch/area managers,
    # falling back to business-scope approvers when none can be inferred.
    # Mirrors Notifications::RequestNotifier#reviewers via the shared resolver.
    def reviewers_for(request)
      Requests::ReviewerResolver.for(request)
    end
  end
end
