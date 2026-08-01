module Finance
  module PosImports
    # Removes rows the user has explicitly marked ignored (via RowIgnorer) from
    # the pipeline, the same way StatusFilter removes non-Success rows —
    # before Validator ever sees them. An ignored row therefore contributes
    # nothing to validation, totals, fees, expense generation, or the
    # imported transaction count; it simply no longer exists as far as the
    # rest of the pipeline is concerned.
    class IgnoredRowsFilter
      Result = Struct.new(:included_rows, :ignored_rows, keyword_init: true)

      def self.call(mapped_rows, ignored_row_numbers)
        new(mapped_rows, ignored_row_numbers).call
      end

      def initialize(mapped_rows, ignored_row_numbers)
        @mapped_rows        = mapped_rows
        @ignored_row_numbers = ignored_row_numbers
      end

      def call
        included, ignored = @mapped_rows.partition { |row| !@ignored_row_numbers.include?(row.row_number) }
        Result.new(included_rows: included, ignored_rows: ignored)
      end
    end
  end
end
