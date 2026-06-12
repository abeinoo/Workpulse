module Adjustments
  # Computes the set of payroll periods an adjustment may target.
  #
  # A period is selectable when payroll has NOT yet been processed for it, i.e.
  # it is still draft or has not been generated at all. Periods that are
  # under_review, branch_review_completed, finalized, or paid are excluded —
  # they are locked against new adjustments (see PayrollAdjustment#period_not_locked).
  #
  # The window covers the current month plus the next few months so users can
  # pre-stage adjustments for upcoming periods (e.g. June / July / August 2026),
  # and additionally surfaces any still-open draft period outside that window.
  class SelectablePeriods
    LOCKED_STATUSES = %w[under_review branch_review_completed finalized paid].freeze
    MONTHS_AHEAD    = 3

    def initialize(business, today: Date.current)
      @business = business
      @today    = today
    end

    # => [["June 2026", "2026-6"], ["July 2026", "2026-7"], ...]
    def options
      candidate_dates
        .reject { |date| locked_keys.include?([ date.year, date.month ]) }
        .uniq
        .sort
        .map { |date| [ label_for(date), "#{date.year}-#{date.month}" ] }
    end

    private

    def candidate_dates
      base = @today.beginning_of_month
      forward = (0..MONTHS_AHEAD).map { |offset| base >> offset }
      forward + open_draft_dates
    end

    # Existing draft periods may sit outside the forward window (e.g. a past month
    # whose payroll was never finalized) but are still valid adjustment targets.
    def open_draft_dates
      PayrollPeriod.for_business(@business)
                   .where(status: "draft")
                   .pluck(:period_year, :period_month)
                   .map { |year, month| Date.new(year, month, 1) }
    end

    def locked_keys
      @locked_keys ||= PayrollPeriod.for_business(@business)
                                    .where(status: LOCKED_STATUSES)
                                    .pluck(:period_year, :period_month)
                                    .to_set
    end

    def label_for(date)
      "#{I18n.t("date.month_names")[date.month]} #{date.year}"
    end
  end
end
