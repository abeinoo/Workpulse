module Payroll
  # Regenerates existing *draft* payroll periods for the given months so freshly
  # written/edited attendance is reflected in pending payslips.
  #
  # Deliberately scoped to draft periods only: finalized/paid (locked) periods are
  # never recalculated — attendance can still be recorded for history/reporting,
  # but it must not silently mutate processed payroll. Never creates new periods.
  #
  # Errors are swallowed and logged so a payroll refresh can never roll back the
  # attendance write that triggered it.
  class DraftRegenerator
    # months: array of [year, month] pairs (duplicates ok — de-duped internally)
    def self.call(business:, months:, triggered_by:)
      new(business: business, months: months, triggered_by: triggered_by).call
    end

    def initialize(business:, months:, triggered_by:)
      @business     = business
      @months       = Array(months).uniq
      @triggered_by = triggered_by
    end

    def call
      @months.each do |year, month|
        period = PayrollPeriod.find_by(
          business:     @business,
          period_year:  year,
          period_month: month,
          status:       "draft"
        )
        next unless period

        Payroll::PeriodGenerator.call(
          business:     @business,
          year:         year,
          month:        month,
          generated_by: @triggered_by
        )
        Rails.logger.info(
          "[DraftRegenerator] Regenerated payroll #{year}/#{month} for business=#{@business.id}"
        )
      rescue => e
        Rails.logger.warn(
          "[DraftRegenerator] Payroll regeneration failed #{year}/#{month} " \
          "business=#{@business.id}: #{e.class}: #{e.message}"
        )
      end
    end
  end
end
