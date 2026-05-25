require "csv"

module Adjustments
  # Parses a CSV file of bulk adjustments.
  # Employees are matched by employee_code (primary), then email, then full name.
  # Returns parsed rows split into valid and invalid sets for preview.
  class BulkCsvParser
    REQUIRED_HEADERS = %w[employee_code amount reason].freeze
    VALID_TYPES      = PayrollAdjustment::ADJUSTMENT_TYPES.freeze

    ParsedRow = Struct.new(
      :row_number, :employee_code, :user, :adjustment_type,
      :amount, :reason, :period_month, :period_year,
      :valid, :errors,
      keyword_init: true
    )

    Result = Struct.new(
      :valid_rows, :invalid_rows, :total_rows, :header_error,
      keyword_init: true
    ) do
      def headers_valid? = header_error.nil?
      def valid_count    = valid_rows.size
      def invalid_count  = invalid_rows.size
    end

    def initialize(csv_data:, business:,
                   default_month: Date.current.month,
                   default_year:  Date.current.year)
      @csv_data      = csv_data.to_s
      @business      = business
      @default_month = default_month
      @default_year  = default_year
    end

    def call
      table = CSV.parse(@csv_data.strip, headers: true, skip_blanks: true)
    rescue CSV::MalformedCSVError => e
      return Result.new(valid_rows: [], invalid_rows: [], total_rows: 0,
                        header_error: "Invalid CSV: #{e.message}")
    else
      missing = missing_headers(table.headers)
      if missing.any?
        return Result.new(valid_rows: [], invalid_rows: [], total_rows: 0,
                          header_error: "Missing required columns: #{missing.join(', ')}")
      end

      # Pre-load all business users for O(1) lookup (avoids N+1 per row)
      users_by_code  = build_user_index(:employee_code)
      users_by_email = build_user_index(:email)
      users_by_name  = build_user_name_index

      parsed = table.each_with_index.map do |row, idx|
        parse_row(row, idx + 2, users_by_code, users_by_email, users_by_name)
      end

      valid   = parsed.select(&:valid)
      invalid = parsed.reject(&:valid)
      Result.new(valid_rows: valid, invalid_rows: invalid, total_rows: parsed.size, header_error: nil)
    end

    private

    def parse_row(row, row_num, by_code, by_email, by_name)
      errs = []

      raw_code = row["employee_code"]&.strip
      user = by_code[raw_code&.downcase] ||
             by_email[raw_code&.downcase] ||
             by_name[raw_code&.downcase]
      errs << "Employee '#{raw_code}' not found" unless user

      raw_amount = row["amount"]&.strip
      amount     = raw_amount.to_f
      errs << "Amount must be greater than 0 (got '#{raw_amount}')" unless amount.positive?

      reason = row["reason"]&.strip
      errs << "Reason is required" if reason.blank?

      raw_type   = row["adjustment_type"]&.strip&.downcase.presence || "cash_incentive"
      adj_type   = VALID_TYPES.include?(raw_type) ? raw_type : nil
      errs << "Invalid adjustment type '#{raw_type}'. Valid: #{VALID_TYPES.join(', ')}" unless adj_type

      period_month = row["period_month"]&.to_i.presence || @default_month
      period_year  = row["period_year"]&.to_i.presence  || @default_year

      if period_month < 1 || period_month > 12
        errs << "Invalid period_month '#{period_month}' (must be 1–12)"
        period_month = @default_month
      end

      ParsedRow.new(
        row_number:      row_num,
        employee_code:   raw_code,
        user:            user,
        adjustment_type: adj_type || "cash_incentive",
        amount:          amount,
        reason:          reason,
        period_month:    period_month,
        period_year:     period_year,
        valid:           errs.empty?,
        errors:          errs
      )
    end

    def build_user_index(field)
      User.where(business: @business, active: true)
          .pluck(:id, field)
          .each_with_object({}) do |(id, val), h|
            h[val.to_s.downcase] = id if val.present?
          end
    end

    def build_user_name_index
      User.where(business: @business, active: true)
          .pluck(:id, :first_name, :last_name)
          .each_with_object({}) do |(id, fn, ln), h|
            full = "#{fn} #{ln}".strip.downcase
            h[full] = id if full.present?
          end
    end

    def missing_headers(headers)
      normalized = Array(headers).map { |h| h&.strip&.downcase }
      REQUIRED_HEADERS.reject { |h| normalized.include?(h) }
    end
  end
end
