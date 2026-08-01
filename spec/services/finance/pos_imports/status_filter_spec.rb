require "rails_helper"

RSpec.describe Finance::PosImports::StatusFilter do
  def row(status:, row_number: 1)
    Finance::PosImports::Mapper::MappedRow.new(
      row_number: row_number,
      attributes: { transaction_id: "TXN-#{row_number}", amount: "10.00", terminal_id: "TERM-1", status: status }
    )
  end

  it "includes a row whose status is exactly Success" do
    result = described_class.call([ row(status: "Success") ])

    expect(result.included_rows.size).to eq(1)
    expect(result.ignored_rows).to be_empty
  end

  it "matches Success case-insensitively and ignores surrounding whitespace" do
    result = described_class.call([ row(status: "  success  "), row(status: "SUCCESS", row_number: 2) ])

    expect(result.included_rows.size).to eq(2)
  end

  %w[Failed Declined Cancelled Reversed Pending Refunded].each do |status|
    it "ignores a row with status #{status.inspect}" do
      result = described_class.call([ row(status: status) ])

      expect(result.included_rows).to be_empty
      expect(result.ignored_rows.size).to eq(1)
    end
  end

  it "ignores a row with a blank status" do
    result = described_class.call([ row(status: "") ])

    expect(result.ignored_rows.size).to eq(1)
  end

  it "partitions a mixed batch correctly" do
    rows = [
      row(status: "Success", row_number: 1),
      row(status: "Failed", row_number: 2),
      row(status: "Success", row_number: 3)
    ]

    result = described_class.call(rows)

    expect(result.included_rows.map(&:row_number)).to eq([ 1, 3 ])
    expect(result.ignored_rows.map(&:row_number)).to eq([ 2 ])
  end
end
