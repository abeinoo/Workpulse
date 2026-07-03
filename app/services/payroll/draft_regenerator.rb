module Payroll
  # Refreshes payroll periods for the given months so freshly written/edited
  # attendance is reflected in pending payslips.
  #
  # Draft periods: full regeneration via PeriodGenerator (all entries rebuilt).
  # Review-state periods (under_review, branch_review_completed): per-entry
  #   recalculation via EntryRecalculator — preserves review progress and branch
  #   sign-offs that would be reset if PeriodGenerator were called.
  # Locked periods (finalized, paid): skipped — attendance may still be recorded
  #   for history and reporting but must not mutate processed payroll.
  #
  # Never creates new periods. Errors are swallowed and logged so a payroll
  # refresh can never roll back the attendance write that triggered it.
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
          business:    @business,
          period_year: year,
          period_month: month
        )
        next unless period && !period.locked?

        if period.draft?
          regenerate_draft(period, year, month)
        else
          recalculate_review_entries(period)
        end
      rescue => e
        Rails.logger.warn(
          "[DraftRegenerator] Failed #{year}/#{month} " \
          "business=#{@business.id}: #{e.class}: #{e.message}"
        )
      end
    end

    private

    def regenerate_draft(_period, year, month)
      Payroll::PeriodGenerator.call(
        business:     @business,
        year:         year,
        month:        month,
        generated_by: @triggered_by
      )
      Rails.logger.info("[DraftRegenerator] Regenerated draft #{year}/#{month} business=#{@business.id}")
    end

    def recalculate_review_entries(period)
      user_ids = period.payroll_entries.pluck(:user_id)
      users    = User.where(id: user_ids).index_by(&:id)

      user_ids.each do |uid|
        Payroll::EntryRecalculator.call(
          user:         users[uid],
          period:       period,
          triggered_by: @triggered_by
        )
      end

      Rails.logger.info(
        "[DraftRegenerator] Recalculated #{user_ids.size} entries for " \
        "#{period.status} period #{period.id} (#{period.period_label})"
      )
    end
  end
end
