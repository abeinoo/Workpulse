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

  context "with the provider's newer \"All Transactions\" layout" do
    # Real header row (abridged) from all_transactions_2026-10-19_2026-10-25:
    # header on row 1, no preamble, "Transaction Amount"/"Paid Date" instead
    # of "Gross Amount"/"Paid At", Terminal ID far to the right (column 37).
    let(:new_layout_header) do
      [ "Transaction ID", "Created Date", "Transaction Amount", "Refunded Amount", "Currency",
        "Transaction Status", "Lifecycle Status", "Payment Channel", "Payment Method",
        "Transaction Fees", "Admin Fee", "Net Transaction Amount", "Paid Date", "Order ID",
        "Merchant Order ID", "Integration ID", "Terminal ID", "RRN", "Created By" ]
    end

    it "finds the header on row 1" do
      result = described_class.call([ new_layout_header, [ "560736704" ] ])

      expect(result.row_index).to eq(0)
      expect(result.headers).to eq(new_layout_header)
    end

    it "finds it under a company-info preamble too" do
      rows = [ [ "All Transactions" ], [ "Merchant Name:", "Salon" ], [], new_layout_header ]

      expect(described_class.call(rows).row_index).to eq(3)
    end
  end

  it "tolerates harmless whitespace, case, and non-breaking spaces in header cells" do
    messy = [ "  transaction id ", "Gross Amount", "Paid\u00A0At", "\uFEFFTERMINAL  ID\t" ]

    result = described_class.call([ [ "Company" ], messy ])

    expect(result.row_index).to eq(1)
  end

  # A row that is recognizably the transactions table but lacks a required
  # column must reach Mapper, which names the missing column — not be
  # reported as "header row not found".
  it "recognizes a header row that is missing a required column, leaving that error to Mapper" do
    result = described_class.call([ [ "Transaction ID", "Status", "Terminal ID" ] ])

    expect(result.row_index).to eq(0)
  end

  it "raises HeaderNotFoundError for an unrelated report, even one sharing some column names" do
    rows = [ [ "Settlement ID", "Gross Amount", "Paid At", "Status" ], [ "S-1", "100", "2026-10-01", "Paid" ] ]

    expect { described_class.call(rows) }.to raise_error(described_class::HeaderNotFoundError)
  end
end
