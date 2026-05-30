module Notifications
  # Reminds employees who checked in but never checked out yesterday to file a
  # punch correction. Idempotent: the Creator's dedup window suppresses repeats
  # if the job runs more than once per day.
  #
  # Scheduled daily (see config/recurring.yml). Iterates per-business so each
  # business's own timezone determines what "yesterday" means.
  class ForgotCheckoutReminderJob < ApplicationJob
    queue_as :background

    def perform
      Business.find_each do |business|
        process_business(business)
      rescue StandardError => e
        Rails.logger.error("[ForgotCheckoutReminderJob] business=#{business.id}: #{e.class}: #{e.message}")
      end
    end

    private

    def process_business(business)
      tz        = business.timezone_object
      yesterday = Time.current.in_time_zone(tz).to_date - 1

      records = AttendanceRecord
                  .for_business(business)
                  .where(work_date: yesterday, status: "incomplete")
                  .includes(:user)

      records.each do |record|
        user = record.user
        next unless user&.active?

        Notifications::Creator.call(
          user:         user,
          event_type:   "attendance_missing_check_out",
          notifiable:   record,
          title:        I18n.t("notifications.attendance.missing_check_out.title"),
          body:         I18n.t("notifications.attendance.missing_check_out.body",
                              date: I18n.l(record.work_date, format: :short)),
          data:         { attendance_record_id: record.id, work_date: record.work_date.to_s },
          dedup_within: 20.hours
        )
      end
    end
  end
end
