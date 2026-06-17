require "rails_helper"

RSpec.describe Finance::Reports::CsvExporter, type: :model do
  it "outputs PURE numeric values for money columns (no currency symbol or grouping)" do
    table = Finance::Reports::Table.new(
      title: "T",
      columns: [
        Finance::Reports::Column.new(key: :label, label: "Branch", money: false),
        Finance::Reports::Column.new(key: :total, label: "Total", money: true)
      ],
      rows: [ { label: "Main", total: BigDecimal("1500.50") } ],
      totals: { total: BigDecimal("1500.50") }
    )

    csv = described_class.new(table).to_csv
    body = csv.sub("﻿", "")
    rows = CSV.parse(body)

    expect(rows[0]).to eq(%w[Branch Total])
    # raw numeric — Excel-friendly: no "SAR", no "ر.س", no thousands comma
    expect(rows[1]).to eq([ "Main", "1500.5" ])
    expect(body).not_to match(/SAR|ر\.س|1,500/)
  end

  it "prepends a UTF-8 BOM for Excel" do
    table = Finance::Reports::Table.new(title: "T",
      columns: [ Finance::Reports::Column.new(key: :label, label: "X", money: false) ],
      rows: [], totals: nil)
    expect(described_class.new(table).to_csv).to start_with("﻿")
  end
end
