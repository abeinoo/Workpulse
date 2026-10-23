module Finance
  module Reports
    # Resolves the Expenses by Type / Expenses by Category filter bar (period
    # preset or custom range, plus branch) into a validated date range, its
    # comparison range, and a branch of the viewer's own business. Parsing and
    # validation only — the reports themselves are computed by ExpenseSummary /
    # ExpenseTrend.
    #
    # Periods are whole calendar months anchored on today's business day
    # (BusinessDay.current, so the business timezone and day roll-over apply):
    #   current_month  — 1st .. last day of this month
    #   previous_month — the complete previous calendar month
    #   last_3_months  — this month and the 2 before it (1st of the first .. end of this month)
    #   last_6_months  — this month and the 5 before it (the default — the range
    #                    these reports have always used)
    #   current_year   — 1 Jan .. 31 Dec of this year
    #   custom         — the submitted from/to dates, inclusive
    #
    # Comparison ("previous period") for a preset is the same number of whole
    # calendar months immediately before it (current_year → the previous year);
    # for a custom range it is the equal-length run of days immediately before
    # it, as these reports have always compared.
    #
    # A request with only from/to (no period — e.g. links from the finance
    # dashboard) is a custom range, so existing URLs keep working. An invalid
    # or reversed custom range is never run: the report falls back to the
    # default period and #error explains why.
    #
    # Branch: view_expense_reports is a business-wide permission, so any branch
    # of the viewer's business may be selected; an id from another business
    # (or garbage) is ignored — the report stays business-wide and #error says
    # so. Never trusted beyond that lookup.
    class ExpenseReportFilters
      PRESETS        = %w[current_month previous_month last_3_months last_6_months current_year custom].freeze
      DEFAULT_PRESET = "last_6_months".freeze
      MONTH_SPANS    = { "current_month" => 1, "last_3_months" => 3, "last_6_months" => 6 }.freeze
      # Postgres rejects far-out dates; anything outside this window is a typo.
      VALID_YEARS    = (1900..2200)

      Result = Struct.new(:preset, :from, :to, :previous_from, :previous_to, :branch, :error, keyword_init: true) do
        def branch_id      = branch&.id
        def range          = { from: from, to: to }
        def previous_range = { from: previous_from, to: previous_to }

        # The params that reproduce exactly this report (CSV link, drill-downs).
        def to_params
          { period: preset, from: from.iso8601, to: to.iso8601, branch_id: branch_id }.compact
        end
      end

      def initialize(business, params, today: nil)
        @business = business
        @params   = params
        @today    = today || BusinessDay.current(context: business)
      end

      def call
        branch, branch_error = resolve_branch
        preset = requested_preset
        from, to, previous_from, previous_to, period_error =
          preset == "custom" ? custom_range : preset_range(preset)

        if period_error
          preset = DEFAULT_PRESET
          from, to, previous_from, previous_to = preset_range(preset)
        end

        Result.new(preset: preset, from: from, to: to, previous_from: previous_from, previous_to: previous_to,
                   branch: branch, error: period_error || branch_error)
      end

      private

      def requested_preset
        value = @params[:period].presence
        return value if PRESETS.include?(value)
        return "custom" if @params[:from].present? || @params[:to].present?

        DEFAULT_PRESET
      end

      def preset_range(preset)
        this_month = @today.beginning_of_month

        case preset
        when "previous_month" then months_from(this_month << 1, 1)
        when "current_year"   then months_from(@today.beginning_of_year, 12)
        else
          span = MONTH_SPANS.fetch(preset)
          months_from(this_month << (span - 1), span)
        end
      end

      # n whole calendar months starting at `first`, and the n months before.
      def months_from(first, months)
        to = (first >> months) - 1
        [ first, to, first << months, first - 1, nil ]
      end

      # Blank side → that side of the default period (the long-standing
      # from/to behavior). Unparseable or reversed → error.
      def custom_range
        default_from, default_to = preset_range(DEFAULT_PRESET)
        from = @params[:from].present? ? parse_date(@params[:from]) : default_from
        to   = @params[:to].present?   ? parse_date(@params[:to])   : default_to

        return [ nil, nil, nil, nil, I18n.t("finance.reports.expense_filters.errors.invalid_date") ] if from.nil? || to.nil?
        return [ nil, nil, nil, nil, I18n.t("finance.reports.expense_filters.errors.reversed_range") ] if from > to

        previous_to = from - 1
        [ from, to, previous_to - (to - from), previous_to, nil ]
      end

      def parse_date(value)
        date = Date.iso8601(value.to_s)
        VALID_YEARS.cover?(date.year) ? date : nil
      rescue ArgumentError, Date::Error
        nil
      end

      def resolve_branch
        raw = @params[:branch_id].presence
        return [ nil, nil ] if raw.nil?

        branch = @business.branches.find_by(id: raw.to_s) if raw.to_s.match?(/\A\d+\z/)
        branch ? [ branch, nil ] : [ nil, I18n.t("finance.reports.expense_filters.errors.branch_unavailable") ]
      end
    end
  end
end
