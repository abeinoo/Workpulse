require "rails_helper"

RSpec.describe Finance::PosImports::BranchResolver do
  let(:business) { create(:business) }
  let(:branch)   { create(:branch, business: business) }

  def row(terminal_id:, amount: "100.00", transaction_id: "TXN-1", row_number: 1)
    Finance::PosImports::Mapper::MappedRow.new(
      row_number: row_number,
      attributes: { transaction_id: transaction_id, amount: amount, terminal_id: terminal_id,
                    status: "Success", product_name: "Service", reference_number: "ORD-1",
                    transaction_date: "2026-07-01 09:05:00" }
    )
  end

  it "resolves a row's branch via its configured terminal" do
    create(:pos_terminal, business: business, branch: branch, terminal_id: "TERM-1")

    result = described_class.call([ row(terminal_id: "TERM-1") ], business: business)

    expect(result.resolved_rows.size).to eq(1)
    expect(result.resolved_rows.first.attributes[:branch_id]).to eq(branch.id)
    expect(result.unknown_terminals).to be_empty
  end

  it "never trusts a branch name/id from the row itself — only the terminal mapping" do
    create(:pos_terminal, business: business, branch: branch, terminal_id: "TERM-1")
    unrelated_row = Finance::PosImports::Mapper::MappedRow.new(
      row_number: 1,
      attributes: { transaction_id: "TXN-1", amount: "1", terminal_id: "TERM-1" }
    )

    result = described_class.call([ unrelated_row ], business: business)

    expect(result.resolved_rows.first.attributes[:branch_id]).to eq(branch.id)
  end

  it "reports one entry per unresolved row, carrying the row's original Excel data" do
    result = described_class.call(
      [ row(terminal_id: "GHOST", amount: "50.00", transaction_id: "TXN-1", row_number: 10),
        row(terminal_id: "GHOST", amount: "25.00", transaction_id: "TXN-2", row_number: 11) ],
      business: business
    )

    expect(result.resolved_rows).to be_empty
    expect(result.unknown_terminals.size).to eq(2)
    first = result.unknown_terminals.first
    expect(first[:row_number]).to eq(10)
    expect(first[:terminal_id]).to eq("GHOST")
    expect(first[:amount]).to eq(50.0.to_d)
    expect(first[:status]).to eq("Success")
    expect(first[:product_name]).to eq("Service")
    expect(first[:reference_number]).to eq("ORD-1")
    expect(first[:transaction_date]).to eq("2026-07-01 09:05:00")
  end

  it "does not resolve via a deactivated terminal" do
    create(:pos_terminal, business: business, branch: branch, terminal_id: "TERM-1", active: false)

    result = described_class.call([ row(terminal_id: "TERM-1") ], business: business)

    expect(result.resolved_rows).to be_empty
    expect(result.unknown_terminals.map { |r| r[:terminal_id] }).to include("TERM-1")
  end

  it "does not resolve a terminal configured for a different business" do
    other_business = create(:business)
    create(:pos_terminal, business: other_business, terminal_id: "TERM-1")

    result = described_class.call([ row(terminal_id: "TERM-1") ], business: business)

    expect(result.resolved_rows).to be_empty
    expect(result.unknown_terminals.map { |r| r[:terminal_id] }).to include("TERM-1")
  end

  it "normalizes terminal_id whitespace on both sides" do
    create(:pos_terminal, business: business, branch: branch, terminal_id: " TERM-1 ")

    result = described_class.call([ row(terminal_id: "TERM-1") ], business: business)

    expect(result.resolved_rows.size).to eq(1)
  end
end
