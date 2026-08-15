require "csv"

module Finance
  module SalesImports
    # Two-phase CSV parser for sales transaction imports.
    #
    # Phase 1 — detect_headers(csv_data):
    #   Reads only the header row. Used to drive the column-mapping UI.
    #
    # Phase 2 — parse(csv_data, column_mapping:):
    #   Extracts canonical fields from each row and returns a ParseResult.
    #   Does NOT persist anything and does NOT perform DR matching.
    #
    # Required fields: transaction_date, branch_name, cashier_name,
    #                  payment_method_name, amount
    # Optional fields: reference_number, transaction_id, sale_number
    class CsvParser
      REQUIRED_FIELDS = %w[transaction_date branch_name cashier_name payment_method_name amount].freeze
      OPTIONAL_FIELDS = %w[reference_number transaction_id sale_number transaction_type].freeze
      ALL_FIELDS      = (REQUIRED_FIELDS + OPTIONAL_FIELDS).freeze

      # A mapped transaction_type cell matching this is a refund/return row.
      # Unmapped, blank, or anything else (e.g. "Sale") is an ordinary sale —
      # amount itself is unaffected either way, still a positive magnitude.
      REFUND_TYPE_PATTERN = /refund|return|مرتجع|استرجاع/i

      # Tried first, in order — the source column's exact time-of-day is
      # preserved whenever one of these matches (never stripped). Only when
      # none of these match do we fall back to DATE_FORMATS below, for
      # sources that genuinely export a date with no time at all.
      DATETIME_FORMATS = [
        "%d %b %Y, %I:%M%p", "%d %B %Y, %I:%M%p",
        "%d %b %Y, %I:%M:%S%p", "%d %B %Y, %I:%M:%S%p",
        "%Y-%m-%d %H:%M:%S", "%Y-%m-%d %H:%M", "%Y-%m-%dT%H:%M:%S",
        "%d/%m/%Y %H:%M:%S", "%d/%m/%Y %H:%M",
        "%m/%d/%Y %H:%M:%S", "%m/%d/%Y %H:%M",
        "%d-%m-%Y %H:%M:%S", "%d-%m-%Y %H:%M"
      ].freeze

      DATE_FORMATS = [
        "%Y-%m-%d", "%d/%m/%Y", "%m/%d/%Y",
        "%d-%m-%Y", "%Y/%m/%d", "%d %b %Y", "%d %B %Y"
      ].freeze

      ParseResult = Struct.new(:valid_rows, :invalid_rows, :total_rows, :header_error, keyword_init: true) do
        def headers_valid? = header_error.nil?
        def valid_count    = valid_rows.size
        def invalid_count  = invalid_rows.size
      end

      # Convert raw bytes (typically ASCII-8BIT from Active Storage) to a clean UTF-8 string
      # without transcoding. `encode("UTF-8", undef: :replace)` on an ASCII-8BIT string
      # treats every byte > 0x7F as "undefined" and drops it, silently erasing Arabic and
      # other multi-byte content. `force_encoding` reinterprets the bytes in-place.
      def self.to_utf8(raw_bytes)
        str = raw_bytes.dup.force_encoding("UTF-8")
        return str if str.valid_encoding?
        # Bytes are not valid UTF-8 — try Windows-1256 (common Arabic Windows export)
        raw_bytes.encode("UTF-8", "Windows-1256", invalid: :replace, undef: :replace, replace: "")
      rescue Encoding::InvalidByteSequenceError, Encoding::UndefinedConversionError
        raw_bytes.encode("UTF-8", invalid: :replace, undef: :replace, replace: "")
      end

      def self.detect_headers(csv_data)
        table = CSV.parse(
          to_utf8(csv_data),
          headers: true, skip_blanks: true
        )
        table.headers.map { |h| h.to_s.strip }
      rescue CSV::MalformedCSVError => e
        raise ArgumentError, "CSV is malformed: #{e.message}"
      end

      def self.parse(csv_data, column_mapping:)
        new(column_mapping: column_mapping).parse(csv_data)
      end

      def initialize(column_mapping:)
        @mapping = column_mapping.transform_keys(&:to_s).transform_values { |v| v.to_s.strip.presence }
      end

      def parse(csv_data)
        missing = REQUIRED_FIELDS.select { |f| @mapping[f].blank? }
        if missing.any?
          return ParseResult.new(
            valid_rows: [], invalid_rows: [], total_rows: 0,
            header_error: "Column mapping missing required fields: #{missing.join(', ')}"
          )
        end

        begin
          table = CSV.parse(
            self.class.to_utf8(csv_data),
            headers: true, skip_blanks: true, liberal_parsing: true
          )
        rescue CSV::MalformedCSVError => e
          return ParseResult.new(
            valid_rows: [], invalid_rows: [], total_rows: 0,
            header_error: "CSV is malformed: #{e.message}"
          )
        end

        valid_rows   = []
        invalid_rows = []

        table.each_with_index do |row, i|
          result = parse_row(row, i + 2)
          result["errors"].any? ? invalid_rows << result : valid_rows << result
        end

        ParseResult.new(
          valid_rows:   valid_rows,
          invalid_rows: invalid_rows,
          total_rows:   valid_rows.size + invalid_rows.size,
          header_error: nil
        )
      end

      private

      def parse_row(row, row_number)
        errors = []
        raw    = {}
        row.each { |k, v| raw[k.to_s] = v.to_s.strip }

        date_str = cell(row, "transaction_date")
        if date_str.blank?
          errors << "transaction_date is required"
          transaction_date = nil
          transaction_time = nil
        else
          transaction_date, transaction_time = try_parse_date_and_time(date_str)
          errors << "transaction_date '#{date_str}' is not a recognised date format" unless transaction_date
        end

        branch_name         = cell(row, "branch_name").presence
        errors << "branch_name is required" if branch_name.blank?

        cashier_name        = cell(row, "cashier_name").presence
        errors << "cashier_name is required" if cashier_name.blank?

        payment_method_name = cell(row, "payment_method_name").presence
        errors << "payment_method_name is required" if payment_method_name.blank?

        amount_str = cell(row, "amount")
        if amount_str.blank?
          errors << "amount is required"
          amount = nil
        else
          cleaned = amount_str.gsub(/[,\s]/, "")
          amount  = BigDecimal(cleaned) rescue nil
          errors << "amount '#{amount_str}' is not a valid number" unless amount
          errors << "amount must be greater than zero" if amount && amount <= 0
        end

        reference_number = cell(row, "reference_number").presence
        transaction_id   = cell(row, "transaction_id").presence
        sale_number      = cell(row, "sale_number").presence
        transaction_type = cell(row, "transaction_type").presence&.match?(REFUND_TYPE_PATTERN) ? "refund" : "sale"

        {
          "row"                  => row_number,
          "transaction_date"     => transaction_date&.to_s,
          "transaction_time"     => transaction_time,
          "branch_name"          => branch_name,
          "cashier_name"         => cashier_name,
          "payment_method_name"  => payment_method_name,
          "amount"               => amount&.to_s("F"),
          "reference_number"     => reference_number,
          "transaction_id"       => transaction_id,
          "sale_number"          => sale_number,
          "transaction_type"     => transaction_type,
          "raw_data"             => raw,
          "valid"                => errors.empty?,
          "errors"               => errors
        }
      end

      def cell(row, canonical_field)
        csv_header = @mapping[canonical_field]
        return "" if csv_header.blank?
        row[csv_header].to_s.strip
      end

      # Returns [Date, "HH:MM:SS" or nil]. Tries every DATETIME_FORMATS
      # pattern first so a source column that includes a time (e.g.
      # "03 Jul 2026, 1:09pm") keeps it — the exact time is never stripped.
      # Only falls back to DATE_FORMATS (time nil) for a source that
      # genuinely has no time component at all.
      def try_parse_date_and_time(str)
        normalized = str.strip

        DATETIME_FORMATS.each do |fmt|
          parsed = DateTime.strptime(normalized, fmt)
          return [ parsed.to_date, parsed.strftime("%H:%M:%S") ]
        rescue Date::Error, ArgumentError
          next
        end

        DATE_FORMATS.each do |fmt|
          return [ Date.strptime(normalized, fmt), nil ]
        rescue Date::Error, ArgumentError
          next
        end

        [ nil, nil ]
      end
    end
  end
end
