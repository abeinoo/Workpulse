require "rails_helper"

RSpec.describe Finance::PosImports::RowIgnorer do
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

  it "ignores a row that is currently a row-level validation error" do
    pos_import = pos_import_with_rows([
      data_row(transaction_id: "TXN-1", amount: "100.00", terminal_id: "TERM-A"),
      data_row(transaction_id: "", amount: "50.00", terminal_id: "TERM-A")
    ])
    invalid_row_number = Finance::PosImports::Pipeline.call(pos_import, business: business)
                                                      .validation.invalid_rows.first[:row_number]

    result = described_class.call(pos_import.id, row_number: invalid_row_number, reason: "Bad export row", actor: actor)

    expect(result).to be_ok
    expect(result.ignored_row.row_number).to eq(invalid_row_number)
    expect(result.ignored_row.reason).to eq("Bad export row")
    expect(result.ignored_row.ignored_by).to eq(actor)
  end

  it "writes an audit log entry" do
    pos_import = pos_import_with_rows([
      data_row(transaction_id: "", amount: "50.00", terminal_id: "TERM-A")
    ])
    invalid_row_number = Finance::PosImports::Pipeline.call(pos_import, business: business)
                                                      .validation.invalid_rows.first[:row_number]

    expect {
      described_class.call(pos_import.id, row_number: invalid_row_number, reason: "Bad row", actor: actor)
    }.to change(AuditLog, :count).by(1)

    log = AuditLog.last
    expect(log.action).to eq("pos_import_row_ignored")
    expect(log.metadata["row_number"]).to eq(invalid_row_number)
  end

  it "rejects ignoring a row that is not currently a validation error" do
    pos_import = pos_import_with_rows([
      data_row(transaction_id: "TXN-1", amount: "100.00", terminal_id: "TERM-A")
    ])

    result = described_class.call(pos_import.id, row_number: 999, reason: "Nope", actor: actor)

    expect(result).not_to be_ok
    expect(result.error).to include("not currently a validation error or an unknown-terminal row")
  end

  it "allows ignoring a single Unknown Terminal ID row without touching the terminal configuration" do
    pos_import = pos_import_with_rows([
      data_row(transaction_id: "TXN-1", amount: "100.00", terminal_id: "TERM-A"),
      data_row(transaction_id: "TXN-2", amount: "50.00", terminal_id: "GHOST-TERM")
    ])
    unknown_row_number = Finance::PosImports::Pipeline.call(pos_import, business: business)
                                                      .resolution.unknown_terminals.first[:row_number]

    result = described_class.call(pos_import.id, row_number: unknown_row_number, reason: "Bad terminal on this row", actor: actor)

    expect(result).to be_ok
    expect(result.ignored_row.row_number).to eq(unknown_row_number)
  end

  it "rejects a missing reason" do
    pos_import = pos_import_with_rows([
      data_row(transaction_id: "", amount: "50.00", terminal_id: "TERM-A")
    ])
    invalid_row_number = Finance::PosImports::Pipeline.call(pos_import, business: business)
                                                      .validation.invalid_rows.first[:row_number]

    result = described_class.call(pos_import.id, row_number: invalid_row_number, reason: "", actor: actor)

    expect(result).not_to be_ok
  end

  it "rejects ignoring the same row twice" do
    pos_import = pos_import_with_rows([
      data_row(transaction_id: "", amount: "50.00", terminal_id: "TERM-A")
    ])
    invalid_row_number = Finance::PosImports::Pipeline.call(pos_import, business: business)
                                                      .validation.invalid_rows.first[:row_number]
    described_class.call(pos_import.id, row_number: invalid_row_number, reason: "First", actor: actor)

    result = described_class.call(pos_import.id, row_number: invalid_row_number, reason: "Second", actor: actor)

    expect(result).not_to be_ok
    expect(pos_import.pos_import_ignored_rows.count).to eq(1)
  end

  it "refuses to ignore rows on an already-imported file" do
    pos_import = pos_import_with_rows([
      data_row(transaction_id: "", amount: "50.00", terminal_id: "TERM-A")
    ])
    pos_import.update_columns(status: "imported")

    result = described_class.call(pos_import.id, row_number: 2, reason: "Too late", actor: actor)

    expect(result).not_to be_ok
    expect(result.error).to include("already been imported")
  end
end
