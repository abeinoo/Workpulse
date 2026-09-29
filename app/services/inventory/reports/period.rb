module Inventory
  module Reports
    # Report period selector. Presets resolve from the business day
    # (BusinessDay), never Date.today:
    #
    #   today · 7d · 30d · month (this month) · last_month · 3m · 6m ·
    #   year (this year) · custom (from/to)
    #
    # Each screen passes its own default and may offer a subset of KEYS.
    # A custom range whose start is after its end is INVALID — it is reported
    # (#invalid?) and the period falls back to the default preset instead of
    # guessing what the user meant.
    class Period
      KEYS    = %w[today 7d 30d month last_month 3m 6m year custom].freeze
      DEFAULT = "30d".freeze

      attr_reader :key, :from, :to, :custom_from, :custom_to

      def initialize(business, key: nil, from: nil, to: nil, default: DEFAULT, keys: KEYS)
        @today       = BusinessDay.current(context: business)
        @default     = default
        @key         = key.presence_in(keys) || default
        @custom_from = Movements.parse_date(from)
        @custom_to   = Movements.parse_date(to)
        @invalid     = @key == "custom" && @custom_from && @custom_to && @custom_from > @custom_to
        @from, @to   = resolve(@invalid ? default : @key)
      end

      def invalid? = @invalid
      def custom?  = @key == "custom"
      def days     = (@to - @from).to_i + 1
      def range    = @from..@to

      private

      def resolve(key)
        t = @today
        case key
        when "today"      then [ t, t ]
        when "7d"         then [ t - 6, t ]
        when "month"      then [ t.beginning_of_month, t ]
        when "last_month" then [ t.prev_month.beginning_of_month, t.prev_month.end_of_month ]
        when "3m"         then [ t.months_ago(3) + 1, t ]
        when "6m"         then [ t.months_ago(6) + 1, t ]
        when "year"       then [ t.beginning_of_year, t ]
        when "custom"     then [ @custom_from || t - 29, @custom_to || t ]
        else                   [ t - 29, t ]
        end
      end
    end
  end
end
