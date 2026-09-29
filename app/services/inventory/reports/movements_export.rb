require "csv"

module Inventory
  module Reports
    # CSV / XLSX export of the Inventory Movement report. Rows come straight
    # from Reports::Movements#each_row — the exact query, filters, order and
    # window balances the screen uses — streamed in batches so a large export
    # never loads the whole ledger at once. Nothing is recalculated here.
    class MovementsExport
      BOM = "﻿".freeze # lets Excel open Arabic CSV correctly
      XLSX_TYPE = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet".freeze
      COLUMNS = %i[date time product sku warehouse movement_type in_quantity out_quantity
                   balance_after unit_cost total_value source document_number].freeze

      def initialize(report, business:)
        @report = report
        @zone   = business.timezone_object || Time.zone
      end

      def filename(extension)
        "inventory_movements_#{Time.current.in_time_zone(@zone).strftime('%Y%m%d_%H%M')}.#{extension}"
      end

      def to_csv
        BOM + CSV.generate do |csv|
          csv << headers
          @report.each_row { |row| csv << values(row) }
        end
      end

      def to_xlsx
        package = Axlsx::Package.new
        package.workbook.add_worksheet(name: I18n.t("inventory.reports.movements.export_sheet")) do |sheet|
          header = sheet.styles.add_style(b: true)
          sheet.add_row headers, style: header
          @report.each_row { |row| sheet.add_row values(row) }
        end
        package.to_stream.read
      end

      private

      def headers
        COLUMNS.map { |key| I18n.t("inventory.reports.export_columns.#{key}") }
      end

      def values(row)
        movement = row.movement
        [
          movement.occurred_on.iso8601,
          movement.created_at.in_time_zone(@zone).strftime("%H:%M"),
          row.product.name,
          row.product.sku,
          row.warehouse.name,
          I18n.t("inventory.movements.reasons.#{row.reason}"),
          row.in_quantity.to_d,
          row.out_quantity.to_d,
          row.balance_after.to_d,
          row.unit_cost.to_d,
          row.total_value.to_d.round(2),
          row.source && I18n.t("inventory.reports.source_types.#{row.source.class.name}", default: row.source.class.name),
          row.document_number
        ]
      end
    end
  end
end
