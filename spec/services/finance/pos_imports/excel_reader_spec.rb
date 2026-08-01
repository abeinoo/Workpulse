require "rails_helper"

RSpec.describe Finance::PosImports::ExcelReader do
  it "reads a well-formed xlsx file into a raw grid of string rows" do
    bytes = XlsxBuilder.build([
      [ "Company Info" ],
      [ "Transaction ID", "Gross Amount" ],
      [ "TXN-1", 100.5 ]
    ])

    grid = described_class.call(bytes, filename: "report.xlsx")

    # Roo pads short rows out to the sheet's widest row — matches how a real
    # provider export behaves (company-info rows are narrower than the table).
    expect(grid.rows).to eq([
      [ "Company Info", "" ],
      [ "Transaction ID", "Gross Amount" ],
      [ "TXN-1", "100.5" ]
    ])
  end

  it "raises MalformedFile for content that isn't a valid xlsx" do
    expect {
      described_class.call("not a real xlsx file", filename: "broken.xlsx")
    }.to raise_error(described_class::MalformedFile)
  end

  it "returns an empty grid for a sheet with no rows" do
    bytes = XlsxBuilder.build([])

    grid = described_class.call(bytes, filename: "empty.xlsx")

    expect(grid.rows).to eq([])
  end

  # Regression: a "Paid At" cell that Excel formats as a full datetime (not
  # plain text) comes back from Roo as a Ruby DateTime — NOT a Time — because
  # Roo::Excelx::Cell::DateTime#value returns a DateTime. DateTime < Date in
  # Ruby, so a naive `when Date, DateTime` branch silently matches it against
  # the date-ONLY format and discards the time-of-day entirely, corrupting
  # every such row to midnight. That in turn can shift the row into the
  # PREVIOUS business day once business_day_start_hour > 0, which is exactly
  # how roughly half of a day's imported POS transactions went missing from
  # the POS Transaction Verification total.
  it "preserves the time-of-day for a real Excel-typed datetime cell (not a plain string)" do
    bytes = XlsxBuilder.build([
      [ "Transaction ID", "Paid At" ],
      [ "TXN-1", XlsxBuilder::ExcelDateTime.new(Time.utc(2026, 7, 12, 14, 35, 0)) ]
    ])

    grid = described_class.call(bytes, filename: "report.xlsx")

    expect(grid.rows.last).to eq([ "TXN-1", "2026-07-12 14:35:00" ])
  end

  it "still reads a genuinely date-only Excel cell as a date, with no time component" do
    bytes = XlsxBuilder.build([
      [ "Created At" ],
      [ XlsxBuilder::ExcelDate.new(Date.new(2026, 7, 12)) ]
    ])

    grid = described_class.call(bytes, filename: "report.xlsx")

    expect(grid.rows.last).to eq([ "2026-07-12" ])
  end

  # No timezone conversion happens anywhere in ExcelReader — a real
  # Excel-typed datetime cell and an equivalent plain-text cell must produce
  # the EXACT same string, byte for byte. If either path silently applied a
  # zone offset, these two would diverge.
  it "produces an identical string for a real Excel datetime cell and an equivalent plain-text cell" do
    typed_bytes = XlsxBuilder.build([
      [ "Paid At" ],
      [ XlsxBuilder::ExcelDateTime.new(Time.utc(2026, 7, 12, 14, 35, 0)) ]
    ])
    text_bytes = XlsxBuilder.build([
      [ "Paid At" ],
      [ "2026-07-12 14:35:00" ]
    ])

    typed_grid = described_class.call(typed_bytes, filename: "typed.xlsx")
    text_grid  = described_class.call(text_bytes, filename: "text.xlsx")

    expect(typed_grid.rows.last).to eq(text_grid.rows.last)
    expect(typed_grid.rows.last).to eq([ "2026-07-12 14:35:00" ])
  end
end
