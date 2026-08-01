require "rails_helper"

RSpec.describe Finance::PosImports::IgnoredRowsFilter do
  def row(row_number)
    Finance::PosImports::Mapper::MappedRow.new(
      row_number: row_number,
      attributes: { transaction_id: "TXN-#{row_number}", amount: "10.00", terminal_id: "TERM-1", status: "Success" }
    )
  end

  it "excludes rows whose row_number is in the ignored set" do
    rows = [ row(8), row(9), row(10) ]

    result = described_class.call(rows, Set.new([ 9 ]))

    expect(result.included_rows.map(&:row_number)).to eq([ 8, 10 ])
    expect(result.ignored_rows.map(&:row_number)).to eq([ 9 ])
  end

  it "includes everything when the ignored set is empty" do
    rows = [ row(8), row(9) ]

    result = described_class.call(rows, Set.new)

    expect(result.included_rows.size).to eq(2)
    expect(result.ignored_rows).to be_empty
  end

  it "ignores every matching row when multiple row_numbers are given" do
    rows = [ row(8), row(9), row(10) ]

    result = described_class.call(rows, Set.new([ 8, 10 ]))

    expect(result.included_rows.map(&:row_number)).to eq([ 9 ])
    expect(result.ignored_rows.map(&:row_number)).to eq([ 8, 10 ])
  end
end
