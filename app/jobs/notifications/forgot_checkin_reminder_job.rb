module Notifications
  # Reminds employees who have an active shift assignment today but have not
  # checked in yet. Intended to run mid-morning (after the typical start time)
  # so genuine early arrivals are never pinged.
  #
  # "Today" is resolved in each business's own timezone.
  class ForgotCheckinReminderJob < ApplicationJob
    queue_as :background

    def perform
      Business.find_each do |business|
        process_business(business)
      rescue StandardError => e
        Rails.logger.error("[ForgotCheckinReminderJob] business=#{business.id}: #{e.class}: #{e.message}")
      end
    end

    private

    def process_business(business)
      today = BusinessDay.current(context: business)

      assignments = ShiftAssignment
                      .active_on(today)
                      .joins(:user)
                      .where(users: { business_id: business.id, active: true })
                      .includes(:user)

      # Users who already have an attendance record today are excluded.
      checked_in_ids = AttendanceRecord
                         .for_business(business)
                         .where(date: today)
                         .pluck(:user_id)
                         .to_set

      assignments.each do |assignment|
        user = assignment.user
        next if checked_in_ids.include?(user.id)

        Notifications::Creator.call(
          user:         user,
          event_type:   "attendance_missing_check_in",
          notifiable:   assignment,
          title:        I18n.t("notifications.attendance.missing_check_in.title"),
          body:         I18n.t("notifications.attendance.missing_check_in.body"),
          data:         { shift_assignment_id: assignment.id, date: today.to_s },
          dedup_within: 8.hours
        )
      end
    end
  end
end
