require "csv"

module Finance
  module BankStatements
    # Two-phase CSV parser for bank statement imports.
    #
    # Phase 1 — detect_headers(csv_data):
    #   Reads only the header row and returns detected column names.
    #   Used to drive the column-mapping step in the UI before any rows are parsed.
    #
    # Phase 2 — parse(csv_data, column_mapping:):
    #   Uses the user-supplied column_mapping to extract canonical fields from each
    #   row. Returns a ParseResult with valid_rows, invalid_rows, and total_rows.
    #   Does NOT persist anything — the importer or controller handles persistence.
    #
    # column_mapping format:
    #   { "transaction_date" => "Value Date", "amount" => "Credit Amount", ... }
    #   Optional fields (reference_number, description, external_transaction_id)
    #   may be absent or map to nil to signal "skip this column".
    class CsvParser
      REQUIRED_FIELDS = %w[transaction_date amount].freeze
      OPTIONAL_FIELDS = %w[reference_number description external_transaction_id].freeze
      ALL_FIELDS      = (REQUIRED_FIELDS + OPTIONAL_FIELDS).freeze

      DATE_FORMATS = [
        "%Y-%m-%d",
        "%d/%m/%Y",
        "%m/%d/%Y",
        "%d-%m-%Y",
        "%Y/%m/%d",
        "%d %b %Y",
        "%d %B %Y"
      ].freeze

      ParseResult = Struct.new(:valid_rows, :invalid_rows, :total_rows, :header_error, keyword_init: true) do
        def headers_valid? = header_error.nil?
        def valid_count    = valid_rows.size
        def invalid_count  = invalid_rows.size
      end

      def self.detect_headers(csv_data)
        table = CSV.parse(
          csv_data.encode("UTF-8", invalid: :replace, undef: :replace, replace: ""),
          headers:     true,
          skip_blanks: true
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
        missing_required = REQUIRED_FIELDS.select { |f| @mapping[f].blank? }
        if missing_required.any?
          return ParseResult.new(
            valid_rows:   [],
            invalid_rows: [],
            total_rows:   0,
            header_error: "Column mapping missing required fields: #{missing_required.join(', ')}"
          )
        end

        begin
          table = CSV.parse(
            csv_data.encode("UTF-8", invalid: :replace, undef: :replace, replace: ""),
            headers:        true,
            skip_blanks:    true,
            liberal_parsing: true
          )
        rescue CSV::MalformedCSVError => e
          return ParseResult.new(
            valid_rows:   [],
            invalid_rows: [],
            total_rows:   0,
            header_error: "CSV is malformed: #{e.message}"
          )
        end

        valid_rows   = []
        invalid_rows = []

        table.each_with_index do |row, i|
          row_number = i + 2
          result     = parse_row(row, row_number)

          if result[:errors].any?
            invalid_rows << result
          else
            valid_rows << result
          end
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

        # Capture all original columns verbatim for raw_data
        row.each { |k, v| raw[k.to_s] = v.to_s.strip }

        # Required: transaction_date
        date_str = cell(row, "transaction_date")
        if date_str.blank?
          errors << "transaction_date is required"
          transaction_date = nil
        else
          transaction_date = try_parse_date(date_str)
          errors << "transaction_date '#{date_str}' is not a recognised date format" unless transaction_date
        end

        # Required: amount
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

        # Optional fields
        reference_number        = cell(row, "reference_number").presence
        description             = cell(row, "description").presence
        external_transaction_id = cell(row, "external_transaction_id").presence

        {
          "row"                     => row_number,
          "transaction_date"        => transaction_date&.to_s,
          "amount"                  => amount&.to_s("F"),
          "reference_number"        => reference_number,
          "description"             => description,
          "external_transaction_id" => external_transaction_id,
          "raw_data"                => raw,
          "valid"                   => errors.empty?,
          "errors"                  => errors
        }
      end

      def cell(row, canonical_field)
        csv_header = @mapping[canonical_field]
        return "" if csv_header.blank?

        row[csv_header].to_s.strip
      end

      def try_parse_date(str)
        DATE_FORMATS.each do |fmt|
          return Date.strptime(str, fmt)
        rescue Date::Error, ArgumentError
          next
        end
        nil
      end
    end
  end
end
