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

      # A header row must contain all of these (normalized) to be recognized —
      # a small, distinctive subset of the full expected column list is enough
      # to avoid false-matching a company-info row.
      SIGNATURE_COLUMNS = [ "transaction id", "gross amount", "paid at", "terminal id" ].freeze

      HeaderResult = Struct.new(:row_index, :headers, keyword_init: true)

      def self.call(rows)
        new(rows).call
      end

      def initialize(rows)
        @rows = rows
      end

      def call
        @rows.first(MAX_SCAN_ROWS).each_with_index do |row, index|
          normalized = row.map { |cell| normalize(cell) }
          next unless SIGNATURE_COLUMNS.all? { |sig| normalized.include?(sig) }

          return HeaderResult.new(row_index: index, headers: row.map { |cell| cell.to_s.strip })
        end

        raise HeaderNotFoundError, "Could not find a header row containing #{SIGNATURE_COLUMNS.join(', ')}"
      end

      private

      def normalize(cell)
        cell.to_s.downcase.gsub(/[\s\-_]+/, " ").strip
      end
    end
  end
end
