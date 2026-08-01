require "rails_helper"

RSpec.describe Finance::PosImports::Validator do
  def mapped_row(row_number: 1, **overrides)
    attrs = {
      transaction_id: "TXN-1", amount: "100.00", status: "Success",
      transaction_date: "2026-07-01 10:00:00", terminal_id: "TERM-1"
    }.merge(overrides)
    Finance::PosImports::Mapper::MappedRow.new(row_number: row_number, attributes: attrs)
  end

  it "accepts a row with every required field present and valid" do
    result = described_class.call([ mapped_row ])

    expect(result.valid_rows.size).to eq(1)
    expect(result.invalid_rows).to be_empty
  end

  it "reports ALL missing/invalid fields on a row, not just the first" do
    row    = mapped_row(transaction_id: "", amount: "", terminal_id: "")
    result = described_class.call([ row ])

    expect(result.valid_rows).to be_empty
    expect(result.invalid_rows.size).to eq(1)
    errors = result.invalid_rows.first[:errors]
    expect(errors).to include(a_string_matching(/Transaction ID/))
    expect(errors).to include(a_string_matching(/Gross Amount/))
    expect(errors).to include(a_string_matching(/Terminal ID/))
  end

  it "flags a non-numeric amount" do
    result = described_class.call([ mapped_row(amount: "not-a-number") ])

    expect(result.invalid_rows.first[:errors]).to include(a_string_matching(/Gross Amount/))
  end

  it "flags an unparseable Paid At date" do
    result = described_class.call([ mapped_row(transaction_date: "not-a-date") ])

    expect(result.invalid_rows.first[:errors]).to include(a_string_matching(/Paid At/))
  end

  it "flags a missing status" do
    result = described_class.call([ mapped_row(status: "") ])

    expect(result.invalid_rows.first[:errors]).to include(a_string_matching(/Status/))
  end

  it "preserves the row_number on invalid rows for error display" do
    result = described_class.call([ mapped_row(row_number: 42, transaction_id: "") ])

    expect(result.invalid_rows.first[:row_number]).to eq(42)
  end

  it "carries the row's original attributes for display, so the source Excel row can be viewed" do
    result = described_class.call([ mapped_row(transaction_id: "", terminal_id: "TERM-9") ])

    expect(result.invalid_rows.first[:attributes]).to eq(
      transaction_id: "", amount: "100.00", status: "Success",
      transaction_date: "2026-07-01 10:00:00", terminal_id: "TERM-9"
    )
  end
end
