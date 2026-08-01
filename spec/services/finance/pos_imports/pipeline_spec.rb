require "rails_helper"

RSpec.describe Finance::PosImports::Pipeline do
  let(:business) { create(:business) }
  let(:branch)   { create(:branch, business: business) }
  let(:actor)    { create(:user, business: business) }

  let(:headers) do
    [ "Transaction ID", "Order ID", "Gross Amount", "Payment Method", "Status",
      "Created At", "Paid At", "Fees", "Administrative Fees", "Product / Order Name",
      "Terminal ID", "Terminal Branch Name", "Branch ID", "Branch Name" ]
  end

  def data_row(transaction_id:, amount:, terminal_id:, status: "Success")
    [ transaction_id, "ORD-#{transaction_id}", amount, "Card", status,
      "2026-07-01 09:00:00", "2026-07-01 09:05:00", "0", "0", "Service", terminal_id, "Ignored", "999", "Ignored" ]
  end

  def pos_import_with_rows(rows)
    pos_import = create(:pos_import, business: business, imported_by: actor)
    bytes = XlsxBuilder.build([ headers ] + rows)
    pos_import.file.attach(io: StringIO.new(bytes), filename: "export.xlsx")
    pos_import
  end

  before { create(:pos_terminal, business: business, branch: branch, terminal_id: "TERM-A") }

  it "excludes a row the user has already marked ignored, before Validator ever sees it" do
    pos_import = pos_import_with_rows([
      data_row(transaction_id: "TXN-1", amount: "100.00", terminal_id: "TERM-A"),
      data_row(transaction_id: "", amount: "50.00", terminal_id: "TERM-A")
    ])

    first_pass = described_class.call(pos_import, business: business)
    invalid_row_number = first_pass.validation.invalid_rows.first[:row_number]
    create(:pos_import_ignored_row, pos_import: pos_import, business: business, ignored_by: actor,
           row_number: invalid_row_number)

    second_pass = described_class.call(pos_import, business: business)

    expect(second_pass.validation.invalid_rows).to be_empty
    expect(second_pass.ignored_split.ignored_rows.map(&:row_number)).to eq([ invalid_row_number ])
    expect(second_pass.resolution.resolved_rows.size).to eq(1)
  end

  it "runs StatusFilter before IgnoredRowsFilter — both exclusions compose" do
    pos_import = pos_import_with_rows([
      data_row(transaction_id: "TXN-1", amount: "100.00", terminal_id: "TERM-A", status: "Success"),
      data_row(transaction_id: "TXN-2", amount: "30.00", terminal_id: "TERM-A", status: "Failed")
    ])

    result = described_class.call(pos_import, business: business)

    expect(result.status_split.ignored_rows.size).to eq(1)
    expect(result.resolution.resolved_rows.size).to eq(1)
  end
end
