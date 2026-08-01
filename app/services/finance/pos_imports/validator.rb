module Finance
  module PosImports
    # Validates each mapped row against the required fields. Reports every
    # error found on a row (not fail-fast) so the preview page can show the
    # user everything that needs fixing in one pass.
    class Validator
      ValidationResult = Struct.new(:valid_rows, :invalid_rows, keyword_init: true)

      def self.call(mapped_rows)
        new(mapped_rows).call
      end

      def initialize(mapped_rows)
        @mapped_rows = mapped_rows
      end

      def call
        valid_rows   = []
        invalid_rows = []

        @mapped_rows.each do |row|
          errors = errors_for(row.attributes)
          if errors.empty?
            valid_rows << row
          else
            invalid_rows << { row_number: row.row_number, errors: errors, attributes: row.attributes }
          end
        end

        ValidationResult.new(valid_rows: valid_rows, invalid_rows: invalid_rows)
      end

      private

      def errors_for(attrs)
        errors = []

        errors << "Transaction ID is required" if blank?(attrs[:transaction_id])
        errors << "Terminal ID is required"    if blank?(attrs[:terminal_id])
        errors << "Status is required"         if blank?(attrs[:status])

        if blank?(attrs[:amount])
          errors << "Gross Amount is required"
        elsif !numeric?(attrs[:amount])
          errors << "Gross Amount must be a number"
        end

        if blank?(attrs[:transaction_date])
          errors << "Paid At is required"
        elsif !parseable_date?(attrs[:transaction_date])
          errors << "Paid At is not a valid date"
        end

        errors
      end

      def blank?(value)
        value.to_s.strip.empty?
      end

      def numeric?(value)
        Float(value.to_s.strip)
        true
      rescue ArgumentError, TypeError
        false
      end

      def parseable_date?(value)
        Time.zone.parse(value.to_s.strip).present?
      rescue ArgumentError, TypeError
        false
      end
    end
  end
end
