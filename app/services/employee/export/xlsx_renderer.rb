module Employee
  module Export
    # Excel workbook for the Employee Data Export (caxlsx, as the inventory
    # report exports): a bold header row, column widths sized to the content,
    # dates as real date cells (YYYY-MM-DD), amounts as numbers with two
    # decimals, text always as text — every text cell is typed :string and the
    # workbook escapes formulas, so nothing is ever evaluated. The sheet reads
    # right to left in an RTL locale.
    module XlsxRenderer
      module_function

      CONTENT_TYPE = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet".freeze
      EXTENSION    = "xlsx".freeze
      CELL_TYPES   = { string: :string, date: :date, decimal: :float }.freeze

      def render(fields, rows)
        package = Axlsx::Package.new
        workbook = package.workbook
        workbook.escape_formulas = true

        workbook.add_worksheet(name: I18n.t("admin.users.export.sheet_name")) do |sheet|
          sheet.sheet_view.right_to_left = rtl?
          header  = sheet.styles.add_style(b: true)
          date    = sheet.styles.add_style(format_code: "yyyy-mm-dd")
          amount  = sheet.styles.add_style(format_code: "#,##0.00")
          styles  = fields.map { { date: date, decimal: amount }[_1.type] }
          types   = fields.map { CELL_TYPES.fetch(_1.type) }

          sheet.add_row fields.map(&:label), style: header, types: Array.new(fields.size, :string)
          rows.each do |row|
            values = fields.each_with_index.map { |field, i| value(field.type, row[i]) }
            sheet.add_row values, types: types, style: styles
          end
        end

        package.to_stream.read
      end

      def value(type, value)
        return nil if value.nil?

        case type
        when :decimal then value.to_d.round(2) # written as an Excel number cell
        when :date    then value
        else value.to_s
        end
      end

      def rtl? = I18n.locale.to_s == "ar"
    end
  end
end
