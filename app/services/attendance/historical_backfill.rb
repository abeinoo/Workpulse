module Attendance
  # One-shot service that corrects attendance records that were imported via
  # CsvImporter before the canonical-pipeline fix.
  #
  # Problem: the old importer hardcoded late_minutes = 0 and early_leave_minutes = 0,
  # and set status = "present" for any checked-out record.  Because payroll
  # (EntryCalculator / PenaltyCalculator) reads those persisted fields verbatim,
  # regenerating payroll from stale records still produces zero deductions.
  #
  # This service:
  #   1. Finds all AttendanceRecord rows with check_in_source = "import".
  #   2. Recomputes late_minutes / early_leave_minutes / worked_minutes / status
  #      using the canonical TimeCalculator pipeline (via RecordRecomputer).
  #   3. Saves changed rows.
  #   4. Regenerates any *draft* PayrollPeriod whose month was touched.
  #
  # Options:
  #   business:     scope to one Business (nil = all businesses)
  #   from/to:      optional work_date range (Date objects)
  #   performed_by: User recorded as the payroll regeneration actor
  #
  # Usage:
  #   Attendance::HistoricalBackfill.call(
  #     business:     Business.find(1),
  #     performed_by: User.find(1)
  #   )
  #
  # Idempotent: safe to run multiple times.  Records already holding the correct
  # values are detected by RecordRecomputer and skipped without a DB write.
  # Payroll regeneration only targets *draft* periods — finalized/paid are untouched.
  class HistoricalBackfill
    Result = Struct.new(
      :records_updated, :records_skipped, :records_failed,
      :payrolls_regenerated, :payrolls_skipped,
      :errors,
      keyword_init: true
    ) do
      def success? = records_failed.zero?

      def summary
        "Records: #{records_updated} updated, #{records_skipped} skipped, " \
        "#{records_failed} failed. " \
        "Payrolls: #{payrolls_regenerated} regenerated, #{payrolls_skipped} skipped."
      end
    end

    def self.call(business: nil, from: nil, to: nil, performed_by:)
      new(business: business, from: from, to: to, performed_by: performed_by).call
    end

    def initialize(business: nil, from: nil, to: nil, performed_by:)
      @business     = business
      @from         = from
      @to           = to
      @performed_by = performed_by
    end

    def call
      scope          = build_scope
      recompute_result = RecordRecomputer.call(scope: scope)

      payrolls_regenerated = 0
      payrolls_skipped     = 0
      payroll_errors       = []

      recompute_result.affected_periods.each do |business_id, year, month|
        begin
          biz    = @business || Business.find(business_id)
          period = PayrollPeriod.find_by(
            business:     biz,
            period_year:  year,
            period_month: month,
            status:       "draft"
          )

          unless period
            payrolls_skipped += 1
            Rails.logger.info(
              "[HistoricalBackfill] No draft payroll for #{year}/#{month} " \
              "business=#{business_id} — skipped"
            )
            next
          end

          Payroll::PeriodGenerator.call(
            business:     biz,
            year:         year,
            month:        month,
            generated_by: @performed_by
          )
          payrolls_regenerated += 1
          Rails.logger.info(
            "[HistoricalBackfill] Regenerated payroll #{year}/#{month} " \
            "for business=#{business_id}"
          )
        rescue => e
          payrolls_skipped += 1
          payroll_errors << {
            business_id: business_id, year: year, month: month,
            error: "#{e.class}: #{e.message}"
          }
          Rails.logger.warn(
            "[HistoricalBackfill] Payroll regeneration failed #{year}/#{month} " \
            "business=#{business_id}: #{e.class}: #{e.message}"
          )
        end
      end

      all_errors = recompute_result.errors + payroll_errors

      Rails.logger.info(
        "[HistoricalBackfill] Done. " \
        "records=#{recompute_result.updated}/#{recompute_result.skipped}/#{recompute_result.failed} " \
        "(updated/skipped/failed) " \
        "payrolls=#{payrolls_regenerated}/#{payrolls_skipped} (regenerated/skipped)"
      )

      Result.new(
        records_updated:      recompute_result.updated,
        records_skipped:      recompute_result.skipped,
        records_failed:       recompute_result.failed,
        payrolls_regenerated: payrolls_regenerated,
        payrolls_skipped:     payrolls_skipped,
        errors:               all_errors
      )
    end

    private

    def build_scope
      scope = AttendanceRecord.where(check_in_source: "import")

      if @business
        scope = scope.joins(:user).where(users: { business_id: @business.id })
      end

      scope = scope.where("work_date >= ?", @from) if @from
      scope = scope.where("work_date <= ?", @to)   if @to
      scope
    end
  end
end
