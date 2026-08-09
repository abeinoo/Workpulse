module Finance
  module Reports
    # Resolves the Expense Details report's filter params into a concrete
    # from/to month range. Pure parsing/validation — no querying, no
    # financial calculation. Backward compatible: a request with only
    # `month`/`year` (no `period_type`) resolves to the exact same
    # single-month range the report has always used.
    class PeriodResolver
      TYPES = %w[single_month last_3_months last_6_months last_12_months custom].freeze
      PRESET_MONTHS = { "last_3_months" => 3, "last_6_months" => 6, "last_12_months" => 12 }.freeze

      Period = Struct.new(:type, :from_year, :from_month, :to_year, :to_month, :error, keyword_init: true) do
        def valid? = error.nil?
        def single_month? = from_year == to_year && from_month == to_month

        def label
          from = I18n.l(Date.new(from_year, from_month, 1), format: "%B %Y")
          return from if single_month?

          to = I18n.l(Date.new(to_year, to_month, 1), format: "%B %Y")
          "#{from} → #{to}"
        end
      end

      def self.call(params)
        new(params).call
      end

      def initialize(params)
        @params = params
      end

      def call
        case type
        when "last_3_months", "last_6_months", "last_12_months" then preset(PRESET_MONTHS.fetch(type))
        when "custom" then custom
        else single_month
        end
      end

      private

      def type
        TYPES.include?(@params[:period_type]) ? @params[:period_type] : "single_month"
      end

      def base_year
        (@params[:year].presence || Date.current.year).to_i
      end

      # Clamped to 1..12 — an out-of-range month param (tampered URL) must
      # never raise ArgumentError out of Date.new; fall back to the current
      # month instead of crashing the page.
      def base_month
        month = (@params[:month].presence || Date.current.month).to_i
        (1..12).cover?(month) ? month : Date.current.month
      end

      def single_month
        Period.new(type: "single_month", from_year: base_year, from_month: base_month,
                   to_year: base_year, to_month: base_month)
      end

      # Anchor ("to") month is the selected month/year; "from" is (n - 1)
      # months before it — an n-month inclusive window ending at the anchor.
      def preset(n)
        to_date   = Date.new(base_year, base_month, 1)
        from_date = to_date << (n - 1)
        Period.new(type: type, from_year: from_date.year, from_month: from_date.month,
                   to_year: to_date.year, to_month: to_date.month)
      end

      def custom
        from_year  = (@params[:from_year].presence  || base_year).to_i
        from_month = (@params[:from_month].presence || base_month).to_i
        to_year    = (@params[:to_year].presence    || base_year).to_i
        to_month   = (@params[:to_month].presence   || base_month).to_i

        begin
          from_date = Date.new(from_year, from_month, 1)
          to_date   = Date.new(to_year, to_month, 1)
        rescue ArgumentError
          return Period.new(type: "custom", from_year: from_year, from_month: from_month,
                            to_year: to_year, to_month: to_month,
                            error: I18n.t("finance.reports.expense_details.period.invalid_range"))
        end

        error = I18n.t("finance.reports.expense_details.period.invalid_range") if from_date > to_date

        Period.new(type: "custom", from_year: from_year, from_month: from_month,
                   to_year: to_year, to_month: to_month, error: error)
      end
    end
  end
end
