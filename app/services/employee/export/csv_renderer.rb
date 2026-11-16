require "csv"

module Employee
  module Export
    # CSV for the Employee Data Export: UTF-8 with a byte-order mark (so Excel
    # opens Arabic text correctly), standard CSV quoting for commas, quotes and
    # line breaks, ISO 8601 dates (YYYY-MM-DD), amounts with two decimals, and
    # every text cell through CellSanitizer.
    module CsvRenderer
      module_function

      BOM          = "﻿".freeze
      CONTENT_TYPE = "text/csv; charset=utf-8".freeze
      EXTENSION    = "csv".freeze

      # rows: an Enumerable of value arrays, typed as `fields` declare.
      def render(fields, rows)
        BOM + CSV.generate do |csv|
          csv << fields.map { CellSanitizer.text(_1.label) }
          rows.each { |row| csv << fields.each_with_index.map { |field, i| cell(field.type, row[i]) } }
        end
      end

      def cell(type, value)
        return nil if value.nil?

        case type
        when :date    then value.iso8601
        when :decimal then ActiveSupport::NumberHelper.number_to_rounded(value, precision: 2)
        else CellSanitizer.text(value.to_s)
        end
      end
    end
  end
end
