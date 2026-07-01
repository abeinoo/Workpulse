module Adjustments
  # Computes the set of payroll periods an adjustment may target.
  #
  # A period is selectable when it is not yet locked for adjustments:
  # either no PayrollPeriod record exists for that month (payroll has not been
  # generated yet — that is fine, adjustments precede generation), or the record
  # is still in "draft" status.
  #
  # Periods that are under_review, branch_review_completed, finalized, or paid
  # are excluded — they are locked against new adjustments.
  #
  # The window always covers the previous calendar month, the current month, and
  # the next few months so users can:
  #   • create adjustments for the just-closed month before generating payroll, and
  #   • pre-stage adjustments for upcoming periods.
  #
  # Any still-open draft PayrollPeriod that sits outside this window (e.g. an old
  # month whose payroll was never finalized) is surfaced as well.
  class SelectablePeriods
    LOCKED_STATUSES = %w[under_review branch_review_completed finalized paid].freeze
    MONTHS_AHEAD    = 3

    def initialize(business, today: Date.current)
      @business = business
      @today    = today
    end

    # => [["May 2026", "2026-5"], ["June 2026", "2026-6"], ...]
    def options
      @options ||= candidate_dates
        .reject { |date| locked_keys.include?([ date.year, date.month ]) }
        .uniq
        .sort
        .map { |date| [ label_for(date), "#{date.year}-#{date.month}" ] }
    end

    # Smart default for form pre-selection:
    #   1. Previous calendar month — if it is selectable (not locked), regardless
    #      of whether a PayrollPeriod record exists for it yet. Adjustments for the
    #      just-closed period are more likely to be the next action than staging a
    #      future month, and payroll need not have been generated first.
    #   2. Current calendar month — if it is selectable.
    #   3. First selectable period — fallback when both are locked.
    def default_key
      prev_date = @today.beginning_of_month << 1
      prev_key  = "#{prev_date.year}-#{prev_date.month}"
      return prev_key if options.any? { |_, k| k == prev_key }

      curr_key = "#{@today.year}-#{@today.month}"
      return curr_key if options.any? { |_, k| k == curr_key }

      options.first&.last
    end

    private

    # Previous month + current month + MONTHS_AHEAD forward months, plus any
    # existing draft PayrollPeriod outside that window.
    def candidate_dates
      base         = @today.beginning_of_month
      prev_month   = base << 1
      forward      = (0..MONTHS_AHEAD).map { |offset| base >> offset }
      ([prev_month] + forward + open_draft_dates).uniq
    end

    # Existing draft periods may sit outside the window (e.g. a period from
    # several months ago whose payroll was never finalized).
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
