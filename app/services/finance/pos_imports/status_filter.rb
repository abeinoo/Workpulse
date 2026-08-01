module Finance
  module PosImports
    # This importer is for settled electronic payment transactions only — a
    # row is processed further only when its Status is exactly "Success"
    # (case-insensitive). Everything else (Failed, Declined, Cancelled,
    # Reversed, blank, or any other value) is ignored completely: it is never
    # passed to Validator (so it has no Paid At/etc. requirement and can never
    # surface as a validation error), never resolved to a branch, never
    # persisted as a PosTransaction, and never counted toward totals, fees,
    # or generated Expenses. Runs immediately after Mapper, before Validator.
    class StatusFilter
      SUCCESS_STATUS = "success".freeze

      Result = Struct.new(:included_rows, :ignored_rows, keyword_init: true)

      def self.call(mapped_rows)
        new(mapped_rows).call
      end

      def initialize(mapped_rows)
        @mapped_rows = mapped_rows
      end

      def call
        included, ignored = @mapped_rows.partition { |row| success?(row) }
        Result.new(included_rows: included, ignored_rows: ignored)
      end

      private

      def success?(row)
        row.attributes[:status].to_s.strip.downcase == SUCCESS_STATUS
      end
    end
  end
end
