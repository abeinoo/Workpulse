require "rails_helper"

RSpec.describe Finance::PosImports::HeaderDetector do
  let(:header_row) do
    [ "Transaction ID", "Order ID", "Gross Amount", "Payment Method", "Status", "Created At", "Paid At",
      "Fees", "Administrative Fees", "Product / Order Name", "Terminal ID", "Terminal Branch Name",
      "Branch ID", "Branch Name" ]
  end

  it "finds the header row even when it is not row 1" do
    rows = [
      [ "Some Company Inc." ],
      [ "Report Period: 2026-07-01 to 2026-07-31" ],
      [],
      [ "Generated at 2026-07-31" ],
      [],
      [],
      header_row,
      [ "TXN-1" ]
    ]

    result = described_class.call(rows)

    expect(result.row_index).to eq(6)
    expect(result.headers).to eq(header_row)
  end

  it "finds the header on row 1 when there is no preamble" do
    result = described_class.call([ header_row, [ "TXN-1" ] ])

    expect(result.row_index).to eq(0)
  end

  it "raises HeaderNotFoundError when no row contains the signature columns" do
    rows = [ [ "Company Info" ], [ "Nothing useful here" ] ]

    expect { described_class.call(rows) }.to raise_error(described_class::HeaderNotFoundError)
  end

  it "does not scan past MAX_SCAN_ROWS" do
    preamble = Array.new(described_class::MAX_SCAN_ROWS) { [ "noise" ] }
    rows     = preamble + [ header_row ]

    expect { described_class.call(rows) }.to raise_error(described_class::HeaderNotFoundError)
  end
end
