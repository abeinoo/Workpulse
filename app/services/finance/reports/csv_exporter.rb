require "csv"

module Finance
  module Reports
    # Renders any report Table to CSV. Prefixed with a UTF-8 BOM so Excel opens
    # Arabic/encoded content correctly. Money columns are emitted as plain numbers.
    class CsvExporter
      BOM = "﻿".freeze

      def initialize(table)
        @table = table
      end

      def to_csv
        BOM + CSV.generate do |csv|
          csv << @table.columns.map(&:label)
          @table.rows.each { |row| csv << @table.columns.map { |c| row[c.key] } }
          csv << totals_row if @table.totals?
        end
      end

      private

      def totals_row
        @table.columns.each_with_index.map do |col, i|
          next @table.totals[col.key] if @table.totals.key?(col.key)

          i.zero? ? I18n.t("finance.reports.total") : nil
        end
      end
    end
  end
end
