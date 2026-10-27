module Finance
  module PosImports
    # Applies the fixed provider->system field mapping (not user-configurable,
    # unlike Finance::SalesImports' column-mapping wizard — the provider's
    # export shape is stable, so there is nothing for a user to choose).
    # Branch Name / Branch ID / Terminal Branch Name are informational only and
    # deliberately absent from FIELD_ALIASES — they are never read, per spec:
    # Terminal ID (via BranchResolver) is the only source of truth for branch.
    class Mapper
      Error = Class.new(StandardError)

      # Carries the missing column labels separately from the message so the
      # controller can interpolate them into its own (localized) sentence.
      class MissingRequiredColumnsError < Error
        attr_reader :missing_columns

        def initialize(missing_columns)
          @missing_columns = missing_columns
          super("Missing required columns: #{missing_columns.join(', ')}")
        end
      end

      # Each system field lists the provider header names that carry it, in
      # priority order. The provider ships more than one "All Transactions"
      # layout: the original one (Gross Amount / Status / Paid At, header on
      # row 7 under a company-info preamble) and a newer one (Transaction
      # Amount / Transaction Status / Paid Date, header on row 1). Same
      # meaning, different names — so they are aliases of one field, never a
      # second code path. "Lifecycle Status" is deliberately NOT a status
      # alias: only the transaction's outcome gates import (see StatusFilter).
      FIELD_ALIASES = {
        transaction_id:      [ "Transaction ID" ],
        reference_number:    [ "Order ID" ],
        amount:              [ "Gross Amount", "Transaction Amount" ],
        payment_method:      [ "Payment Method" ],
        status:              [ "Status", "Transaction Status" ],
        transaction_date:    [ "Paid At", "Paid Date" ],
        provider_created_at: [ "Created At", "Created Date" ],
        terminal_id:         [ "Terminal ID" ],
        fees:                [ "Fees", "Transaction Fees" ],
        administrative_fees: [ "Administrative Fees", "Admin Fee" ],
        product_name:        [ "Product / Order Name" ]
      }.freeze

      REQUIRED_FIELDS = %i[transaction_id amount transaction_date status terminal_id].freeze

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
        column_index_for = self.class.column_indexes(@headers)
        missing = REQUIRED_FIELDS - column_index_for.keys
        if missing.any?
          raise MissingRequiredColumnsError, missing.map { |field| FIELD_ALIASES[field].join(" / ") }
        end

        @data_rows.each_with_index.filter_map do |values, offset|
          next if values.all? { |v| v.to_s.strip.empty? }

          attributes = column_index_for.transform_values { |index| values[index] }
          MappedRow.new(row_number: @starting_row + offset, attributes: attributes)
        end
      end

      # { field => column index } for every field whose header is present.
      # The first alias found wins, then the leftmost column for that alias.
      def self.column_indexes(headers)
        normalized = headers.map { |h| normalize(h) }

        FIELD_ALIASES.each_with_object({}) do |(field, aliases), hash|
          index = aliases.lazy.filter_map { |name| normalized.index(normalize(name)) }.first
          hash[field] = index if index
        end
      end

      # Case/separator-insensitive; [[:space:]] also covers the non-breaking
      # spaces and BOMs that spreadsheet exports sometimes leave in headers.
      def self.normalize(header)
        header.to_s.downcase.gsub(/[[:space:]\uFEFF\-_]+/, " ").strip
      end
    end
  end
end
