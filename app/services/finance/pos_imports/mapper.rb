module Finance
  module PosImports
    # Applies the fixed provider->system field mapping (not user-configurable,
    # unlike Finance::SalesImports' column-mapping wizard — the provider's
    # export shape is stable, so there is nothing for a user to choose).
    # Branch Name / Branch ID / Terminal Branch Name are informational only and
    # deliberately absent from FIELD_MAP — they are never read, per spec:
    # Terminal ID (via BranchResolver) is the only source of truth for branch.
    class Mapper
      Error                       = Class.new(StandardError)
      MissingRequiredColumnsError = Class.new(Error)

      FIELD_MAP = {
        "transaction id"      => :transaction_id,
        "order id"            => :reference_number,
        "gross amount"        => :amount,
        "payment method"      => :payment_method,
        "status"              => :status,
        "paid at"             => :transaction_date,
        "created at"          => :provider_created_at,
        "terminal id"         => :terminal_id,
        "fees"                => :fees,
        "administrative fees" => :administrative_fees,
        "product / order name" => :product_name
      }.freeze

      REQUIRED_HEADERS = %w[transaction\ id gross\ amount paid\ at status terminal\ id].freeze

      MappedRow = Struct.new(:row_number, :attributes, keyword_init: true)

      def self.call(headers:, data_rows:, starting_row:)
        new(headers: headers, data_rows: data_rows, starting_row: starting_row).call
      end

      def initialize(headers:, data_rows:, starting_row:)
        @headers      = headers
        @data_rows    = data_rows
        @starting_row = starting_row
      end

      def call
        normalized_headers = @headers.map { |h| normalize(h) }
        missing = REQUIRED_HEADERS - normalized_headers
        if missing.any?
          raise MissingRequiredColumnsError, "Missing required columns: #{missing.join(', ')}"
        end

        column_index_for = normalized_headers.each_with_index.each_with_object({}) do |(header, index), hash|
          field = FIELD_MAP[header]
          hash[field] ||= index if field
        end

        @data_rows.each_with_index.filter_map do |values, offset|
          next if values.all? { |v| v.to_s.strip.empty? }

          attributes = column_index_for.transform_values { |index| values[index] }
          MappedRow.new(row_number: @starting_row + offset, attributes: attributes)
        end
      end

      private

      def normalize(header)
        header.to_s.downcase.gsub(/[\s\-_]+/, " ").strip
      end
    end
  end
end
