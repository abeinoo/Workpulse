module Payroll
  # Runs daily via Solid Queue recurring schedule.
  # Iterates all businesses and calls AutoGenerator for each.
  # Each business is isolated: a failure in one does not block others.
  class AutoGenerateJob < ApplicationJob
    queue_as :background

    def perform
      Business.where.not(payroll_auto_generate_day: nil).find_each do |business|
        result = Payroll::AutoGenerator.call(business: business)

        if result.success?
          Rails.logger.info "[AutoPayroll] Generated #{result.period.period_label} for #{business.name}"

          # Notify the business owner of the auto-generated period
          notify_owner(business, result.period)
        elsif result.error
          Rails.logger.error "[AutoPayroll] Failed for #{business.name}: #{result.error}"
        end
      rescue StandardError => e
        Rails.logger.error "[AutoPayroll] Unexpected error for business #{business.id}: #{e.message}"
      end
    end

    private

    def notify_owner(business, period)
      owner = business.owner
      return unless owner

      Notification.create!(
        user:          owner,
        notifiable:    period,
        event_type:    "payroll_auto_generated",
        title:         I18n.t("notifications.payroll_auto_generated.title",
                               label: period.period_label),
        body:          I18n.t("notifications.payroll_auto_generated.body",
                               label:    period.period_label,
                               business: business.name),
        severity:      "info"
      )
    end
  end
end
