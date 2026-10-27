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

  it "names every missing required column, with its accepted aliases" do
    incomplete_headers = headers - [ "Gross Amount", "Paid At" ]

    expect {
      described_class.call(headers: incomplete_headers, data_rows: [ data_row ], starting_row: 8)
    }.to raise_error(described_class::MissingRequiredColumnsError) { |error|
      expect(error.missing_columns).to eq([ "Gross Amount / Transaction Amount", "Paid At / Paid Date" ])
    }
  end

  context "with the provider's newer \"All Transactions\" layout" do
    let(:new_headers) do
      [ "Transaction ID", "Created Date", "Transaction Amount", "Refunded Amount", "Transaction Status",
        "Lifecycle Status", "Payment Channel", "Payment Method", "Transaction Fees", "Admin Fee",
        "Net Transaction Amount", "Paid Date", "Order ID", "Merchant Order ID", "Terminal ID" ]
    end

    let(:new_row) do
      [ "560736704", "2026-10-25 23:53:57", "360", "---", "Success", "Sell", "POS", "Card", "4.92", "---",
        "355.08", "2026-10-25 23:54:00", "639639463", "---", "948998" ]
    end

    it "maps the renamed columns onto the same system fields" do
      result = described_class.call(headers: new_headers, data_rows: [ new_row ], starting_row: 2)

      expect(result.first.attributes).to eq(
        transaction_id:       "560736704",
        reference_number:     "639639463",
        amount:               "360",
        payment_method:       "Card",
        status:               "Success",
        transaction_date:     "2026-10-25 23:54:00",
        provider_created_at:  "2026-10-25 23:53:57",
        terminal_id:          "948998",
        fees:                 "4.92",
        administrative_fees:  "---"
      )
    end

    it "never reads Net Transaction Amount or Lifecycle Status in place of the gross amount / transaction status" do
      result = described_class.call(headers: new_headers, data_rows: [ new_row ], starting_row: 2)

      expect(result.first.attributes[:amount]).to eq("360")
      expect(result.first.attributes[:status]).to eq("Success")
    end

    it "raises MissingRequiredColumnsError when Terminal ID is absent" do
      expect {
        described_class.call(headers: new_headers - [ "Terminal ID" ], data_rows: [ new_row ], starting_row: 2)
      }.to raise_error(described_class::MissingRequiredColumnsError, /Terminal ID/)
    end
  end
end
