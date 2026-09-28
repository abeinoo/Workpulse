# Builds real .xlsx bytes (via caxlsx, the app's own workbook writer) for
# import specs. `rows` is an array of arrays; the first is the header row.
# `types` optionally forces per-column cell types (e.g. :string for SKUs) on
# the data rows; the header row is always text.
module XlsxHelpers
  def xlsx_bytes(rows, types: nil, sheet_name: "Sheet1")
    package = Axlsx::Package.new
    package.workbook.add_worksheet(name: sheet_name) do |sheet|
      rows.each_with_index { |row, i| sheet.add_row(row, types: i.zero? ? nil : types) }
    end
    package.to_stream.read
  end
end

RSpec.configure do |config|
  config.include XlsxHelpers
end
