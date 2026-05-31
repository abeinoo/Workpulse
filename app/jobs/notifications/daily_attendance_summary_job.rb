module Notifications
  # Sends each manager a once-daily summary of their team's attendance gaps:
  # how many of their managed employees are missing an attendance record today.
  # One notification per manager (deduped), category "attendance".
  #
  # Runs late-morning per business timezone so the picture is meaningful.
  class DailyAttendanceSummaryJob < ApplicationJob
    queue_as :background

    def perform
      Business.find_each do |business|
        process_business(business)
      rescue StandardError => e
        Rails.logger.error("[DailyAttendanceSummaryJob] business=#{business.id}: #{e.class}: #{e.message}")
      end
    end

    private

    def process_business(business)
      today = BusinessDay.current(context: business)

      managers = business.users.where(active: true).select { |u| u.managed_employees.exists? }
      return if managers.empty?

      managers.each do |manager|
        team_ids = manager.managed_employees.where(active: true).pluck(:id)
        next if team_ids.empty?

        present_ids = AttendanceRecord.where(user_id: team_ids, date: today).pluck(:user_id).to_set
        missing = team_ids.reject { |id| present_ids.include?(id) }
        next if missing.empty?

        Notifications::Creator.call(
          user:         manager,
          event_type:   "manager_missing_attendance",
          title:        I18n.t("notifications.attendance.manager_summary.title", count: missing.size),
          body:         I18n.t("notifications.attendance.manager_summary.body",
                              count: missing.size, total: team_ids.size),
          data:         { missing_count: missing.size, team_size: team_ids.size, date: today.to_s },
          dedup_within: 20.hours
        )
      end
    end
  end
end
