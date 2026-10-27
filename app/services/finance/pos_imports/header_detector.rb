module Finance
  module PosImports
    # Scans the raw grid returned by ExcelReader for the real header row. The
    # provider report places company-info rows before the table (currently
    # around row 7, but this must never be hardcoded — it scans until it finds
    # a row containing the signature columns below).
    class HeaderDetector
      Error               = Class.new(StandardError)
      HeaderNotFoundError = Class.new(Error)

      MAX_SCAN_ROWS = 30

      # A header row must contain both of these to be recognized — a
      # distinctive pair no company-info row carries, and named identically in
      # every provider layout (see Mapper::FIELD_ALIASES). Deliberately not the
      # full required set: a recognized header that lacks e.g. an amount column
      # must surface as Mapper::MissingRequiredColumnsError naming the missing
      # column, not as an opaque "header not found".
      SIGNATURE_FIELDS = %i[transaction_id terminal_id].freeze

      HeaderResult = Struct.new(:row_index, :headers, keyword_init: true)

      def self.call(rows)
        new(rows).call
      end

      def initialize(rows)
        @rows = rows
      end

      def call
        @rows.first(MAX_SCAN_ROWS).each_with_index do |row, index|
          next unless (SIGNATURE_FIELDS - Mapper.column_indexes(row).keys).empty?

          return HeaderResult.new(row_index: index, headers: row.map { |cell| cell.to_s.strip })
        end

        labels = SIGNATURE_FIELDS.map { |field| Mapper::FIELD_ALIASES[field].first }
        raise HeaderNotFoundError, "Could not find a header row containing #{labels.join(', ')}"
      end
    end
  end
end
