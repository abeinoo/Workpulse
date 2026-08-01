require "rails_helper"

RSpec.describe Finance::PosImports::Mapper do
  let(:headers) do
    [ "Transaction ID", "Order ID", "Gross Amount", "Payment Method", "Status", "Created At", "Paid At",
      "Fees", "Administrative Fees", "Product / Order Name", "Terminal ID", "Terminal Branch Name",
      "Branch ID", "Branch Name" ]
  end

  let(:data_row) do
    [ "TXN-1", "ORD-1", "100.50", "Card", "Success", "2026-07-01 10:00:00", "2026-07-01 10:05:00",
      "2.50", "1.00", "Haircut", "TERM-1", "Main Branch Terminal", "1", "Main Branch" ]
  end

  it "maps every fixed field to the correct system attribute" do
    result = described_class.call(headers: headers, data_rows: [ data_row ], starting_row: 8)

    expect(result.first.attributes).to eq(
      transaction_id:       "TXN-1",
      reference_number:     "ORD-1",
      amount:               "100.50",
      payment_method:       "Card",
      status:               "Success",
      provider_created_at:  "2026-07-01 10:00:00",
      transaction_date:     "2026-07-01 10:05:00",
      fees:                 "2.50",
      administrative_fees:  "1.00",
      product_name:         "Haircut",
      terminal_id:          "TERM-1"
    )
  end

  it "ignores Branch Name, Branch ID, and Terminal Branch Name entirely" do
    result = described_class.call(headers: headers, data_rows: [ data_row ], starting_row: 8)

    expect(result.first.attributes.keys).not_to include(:branch_name, :branch_id, :terminal_branch_name)
  end

  it "numbers rows starting from starting_row" do
    result = described_class.call(headers: headers, data_rows: [ data_row, data_row ], starting_row: 8)

    expect(result.map(&:row_number)).to eq([ 8, 9 ])
  end

  it "skips fully blank rows without breaking row numbering intent" do
    result = described_class.call(headers: headers, data_rows: [ data_row, [] ], starting_row: 8)

    expect(result.size).to eq(1)
  end

  it "raises MissingRequiredColumnsError when a required column is absent" do
    incomplete_headers = headers - [ "Terminal ID" ]

    expect {
      described_class.call(headers: incomplete_headers, data_rows: [ data_row ], starting_row: 8)
    }.to raise_error(described_class::MissingRequiredColumnsError)
  end
end
