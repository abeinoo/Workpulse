module Finance
  module BankStatements
    # Format-agnostic row parser for bank statement imports. Operates on the
    # generic Table (headers + rows) produced by FileReader, so the same logic
    # validates and extracts canonical fields whether the source file was CSV
    # or Excel — no file-format concerns leak into this class.
    #
    # Usage:
    #   table  = Finance::BankStatements::FileReader.read(io, filename: filename)
    #   result = Finance::BankStatements::RowParser.parse(table, column_mapping: mapping)
    #
    # column_mapping format:
    #   { "transaction_date" => "Value Date", "amount" => "Credit Amount", ... }
    #   Optional fields (reference_number, description, external_transaction_id,
    #   transaction_type) may be absent or map to nil to signal "skip this column".
    class RowParser
      REQUIRED_FIELDS = %w[transaction_date amount].freeze
      OPTIONAL_FIELDS = %w[reference_number description external_transaction_id transaction_type].freeze
      ALL_FIELDS      = (REQUIRED_FIELDS + OPTIONAL_FIELDS).freeze

      ParseResult = Struct.new(:valid_rows, :invalid_rows, :total_rows, :header_error, keyword_init: true) do
        def headers_valid? = header_error.nil?
        def valid_count    = valid_rows.size
        def invalid_count  = invalid_rows.size
      end

      def self.parse(table, column_mapping:)
        new(column_mapping: column_mapping).parse(table)
      end

      def initialize(column_mapping:)
        @mapping = column_mapping.transform_keys(&:to_s).transform_values { |v| v.to_s.strip.presence }
      end

      def parse(table)
        missing_required = REQUIRED_FIELDS.select { |f| @mapping[f].blank? }
        if missing_required.any?
          translated_fields = missing_required.map { |f| I18n.t("finance.bank_statements.fields.#{f}") }
          return ParseResult.new(
            valid_rows:   [],
            invalid_rows: [],
            total_rows:   0,
            header_error: I18n.t("finance.bank_statements.errors.mapping_missing_fields",
                                  fields: translated_fields.join(", "))
          )
        end

        valid_rows   = []
        invalid_rows = []

        table.rows.each_with_index do |row_hash, i|
          row_number = i + 2
          result     = parse_row(row_hash, row_number)

          if result["errors"].any?
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

      def parse_row(row_hash, row_number)
        errors = []
        raw    = {}

        # Capture all original columns verbatim for raw_data
        row_hash.each { |k, v| raw[k] = v.to_s.strip }

        # Required: transaction_date
        date_str = cell(row_hash, "transaction_date")
        if date_str.blank?
          errors << I18n.t("finance.bank_statements.row_errors.transaction_date_required")
          transaction_date = nil
        else
          begin
            transaction_date = DateParser.parse(date_str)
          rescue DateParser::InvalidDateError => e
            Rails.logger.info(
              "[Finance::BankStatements::RowParser] row #{row_number}: unparseable transaction_date #{date_str.inspect}"
            )
            errors << e.message
            transaction_date = nil
          end
        end

        # Required: amount
        amount_str = cell(row_hash, "amount")
        if amount_str.blank?
          errors << I18n.t("finance.bank_statements.row_errors.amount_required")
          amount = nil
        else
          cleaned = amount_str.gsub(/[,\s]/, "")
          begin
            amount = BigDecimal(cleaned)
          rescue ArgumentError, TypeError => e
            Rails.logger.info(
              "[Finance::BankStatements::RowParser] row #{row_number}: unparseable amount #{amount_str.inspect} (#{e.message})"
            )
            amount = nil
          end
          errors << I18n.t("finance.bank_statements.row_errors.amount_invalid", value: amount_str) unless amount
          errors << I18n.t("finance.bank_statements.row_errors.amount_not_positive") if amount && amount <= 0
        end

        # Optional fields
        reference_number        = cell(row_hash, "reference_number").presence
        description              = cell(row_hash, "description").presence
        external_transaction_id  = cell(row_hash, "external_transaction_id").presence
        transaction_type         = cell(row_hash, "transaction_type").presence

        {
          "row"                     => row_number,
          "transaction_date"        => transaction_date&.to_s,
          "amount"                  => amount&.to_s("F"),
          "reference_number"        => reference_number,
          "description"             => description,
          "external_transaction_id" => external_transaction_id,
          "transaction_type"        => transaction_type,
          "raw_data"                => raw,
          "valid"                   => errors.empty?,
          "errors"                  => errors
        }
      end

      def cell(row_hash, canonical_field)
        header = @mapping[canonical_field]
        return "" if header.blank?

        row_hash[header].to_s.strip
      end
    end
  end
end
