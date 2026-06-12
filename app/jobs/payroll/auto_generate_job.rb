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
        elsif result.error
          Rails.logger.error "[AutoPayroll] Failed for #{business.name}: #{result.error}"
        end
      rescue StandardError => e
        Rails.logger.error "[AutoPayroll] Unexpected error for business #{business.id}: #{e.message}"
      end
    end
  end
end
