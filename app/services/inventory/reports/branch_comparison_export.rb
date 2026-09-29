require "csv"

module Inventory
  module Reports
    # CSV / XLSX export of the Branch Comparison report: the branch rows and
    # the warehouse reconciliation rows exactly as BranchComparison computed
    # them — nothing recalculated here. XLSX has one sheet per table; CSV
    # stacks them with a blank line between.
    class BranchComparisonExport
      BOM = "﻿".freeze
      XLSX_TYPE = MovementsExport::XLSX_TYPE

      BRANCH_COLUMNS = %i[branch warehouse link_source shared warehouse_stock issued reversed net_consumption
                          consumption_value share avg_daily_consumption coverage_days last_consumed_on].freeze
      WAREHOUSE_COLUMNS = %i[warehouse branches opening receipts transfers_in transfers_out adjustments_in
                             adjustments_out consumption reversals closing current_stock stock_value
                             avg_daily_consumption coverage_days].freeze

      def initialize(report)
        @report = report
      end

      def filename(extension)
        "branch_comparison_#{@report.product.sku.parameterize}_#{@report.from.iso8601}_#{@report.to.iso8601}.#{extension}"
      end

      def to_csv
        BOM + CSV.generate do |csv|
          csv << [ @report.product.name, @report.product.sku, @report.from.iso8601, @report.to.iso8601 ]
          csv << []
          csv << headers(BRANCH_COLUMNS)
          @report.branch_rows.each { |row| csv << branch_values(row) }
          csv << []
          csv << headers(WAREHOUSE_COLUMNS)
          @report.warehouse_rows.each { |row| csv << warehouse_values(row) }
        end
      end

      def to_xlsx
        package = Axlsx::Package.new
        bold = package.workbook.styles.add_style(b: true)
        package.workbook.add_worksheet(name: t("branches_sheet")) do |sheet|
          sheet.add_row headers(BRANCH_COLUMNS), style: bold
          @report.branch_rows.each { |row| sheet.add_row branch_values(row) }
        end
        package.workbook.add_worksheet(name: t("warehouses_sheet")) do |sheet|
          sheet.add_row headers(WAREHOUSE_COLUMNS), style: bold
          @report.warehouse_rows.each { |row| sheet.add_row warehouse_values(row) }
        end
        package.to_stream.read
      end

      private

      def t(key) = I18n.t("inventory.reports.branch_comparison.export.#{key}")

      def headers(columns) = columns.map { |c| t("columns.#{c}") }

      def num(value) = value&.to_d&.round(2)

      def branch_values(row)
        [ row.branch.name, row.warehouses.map(&:name).join(" / "),
          row.source ? t("sources.#{row.source}") : nil,
          row.shared? ? t("yes") : t("no"), num(row.warehouse_stock),
          num(row.issued), num(row.reversed), num(row.net_consumption), num(row.consumption_value),
          num(row.share), num(row.avg_daily_consumption), num(row.coverage_days), row.last_consumed_on&.iso8601 ]
      end

      def warehouse_values(row)
        [ row.warehouse.name, row.branches.map(&:name).join(" / "), num(row.opening), num(row.receipts),
          num(row.transfers_in), num(row.transfers_out), num(row.adjustments_in), num(row.adjustments_out),
          num(row.consumption), num(row.reversals), num(row.closing), num(row.current_stock), num(row.stock_value),
          num(row.avg_daily_consumption), num(row.coverage_days) ]
      end
    end
  end
end
