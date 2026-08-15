require "rails_helper"

RSpec.describe Finance::SalesImports::Importer do
  let(:business) { create(:business) }
  let(:branch)   { create(:branch, business: business) }
  let(:actor)    { create(:user, business: business) }

  let(:headers) { %w[Date Branch Cashier Method Amount Ref SaleNo] }
  let(:column_mapping) do
    {
      "transaction_date"    => "Date",
      "branch_name"         => "Branch",
      "cashier_name"        => "Cashier",
      "payment_method_name" => "Method",
      "amount"              => "Amount",
      "reference_number"    => "Ref",
      "sale_number"         => "SaleNo"
    }
  end

  def sales_import_with_rows(rows)
    require "csv"
    csv = CSV.generate do |c|
      c << headers
      rows.each { |r| c << r }
    end
    sales_import = SalesImport.create!(business: business, imported_by: actor, file_name: "export.csv",
                                       status: "column_mapped", column_mapping: column_mapping)
    sales_import.file.attach(io: StringIO.new(csv), filename: "export.csv", content_type: "text/csv")
    sales_import
  end

  let!(:dr) do
    DailyReconciliation.create!(
      branch: branch, business: business, state: "closed",
      opened_at: 1.hour.ago, closed_at: Time.current, business_date: Date.new(2026, 7, 28)
    )
  end
  let!(:till_session) { TillSession.create!(daily_reconciliation: dr, depositor_id: actor.id) }
  let!(:cash_pm) { PaymentMethod.create!(business: business, name: "Cash", settlement_type: "cash", active: true) }

  it "stores the exact transaction_time from a combined date+time source column — never just the date" do
    sales_import = sales_import_with_rows([
      [ "28 Jul 2026, 11:48am", branch.name, actor.full_name, "Cash", "100.00", "REF-1", "SHT-1" ]
    ])

    result = described_class.call(sales_import.id, actor: actor)
    expect(result).to be_ok

    txn = SalesTransaction.find_by(reference_number: "REF-1")
    expect(txn.transaction_date).to eq(Date.new(2026, 7, 28))
    expect(txn.transaction_time.strftime("%H:%M:%S")).to eq("11:48:00")
  end

  it "stores sale_number distinctly from reference_number" do
    sales_import = sales_import_with_rows([
      [ "28 Jul 2026, 11:48am", branch.name, actor.full_name, "Cash", "100.00", "REF-1", "SHT-1" ]
    ])

    described_class.call(sales_import.id, actor: actor)

    txn = SalesTransaction.find_by(reference_number: "REF-1")
    expect(txn.sale_number).to eq("SHT-1")
  end

  it "defaults transaction_type to 'sale' when the CSV has no type column" do
    sales_import = sales_import_with_rows([
      [ "28 Jul 2026, 11:48am", branch.name, actor.full_name, "Cash", "100.00", "REF-1", "SHT-1" ]
    ])

    described_class.call(sales_import.id, actor: actor)

    txn = SalesTransaction.find_by(reference_number: "REF-1")
    expect(txn.transaction_type).to eq("sale")
    expect(txn.refund?).to be(false)
  end

  it "persists transaction_type: refund when the CSV maps and marks a refund row" do
    mapping = column_mapping.merge("transaction_type" => "Type")
    headers_with_type = headers + %w[Type]
    csv = CSV.generate do |c|
      c << headers_with_type
      c << [ "28 Jul 2026, 11:48am", branch.name, actor.full_name, "Cash", "100.00", "REF-1", "SHT-1", "Sale" ]
      c << [ "28 Jul 2026, 11:50am", branch.name, actor.full_name, "Cash", "20.00",  "REF-2", "SHT-2", "Refund" ]
    end
    sales_import = SalesImport.create!(business: business, imported_by: actor, file_name: "export.csv",
                                       status: "column_mapped", column_mapping: mapping)
    sales_import.file.attach(io: StringIO.new(csv), filename: "export.csv", content_type: "text/csv")

    result = described_class.call(sales_import.id, actor: actor)
    expect(result).to be_ok

    sale   = SalesTransaction.find_by(reference_number: "REF-1")
    refund = SalesTransaction.find_by(reference_number: "REF-2")
    expect(sale.transaction_type).to eq("sale")
    expect(refund.transaction_type).to eq("refund")
    expect(refund.amount).to eq(20) # stored as a positive magnitude
    expect(refund.signed_amount).to eq(-20)
  end

  it "leaves transaction_time nil for a genuinely date-only source, without failing the import" do
    sales_import = sales_import_with_rows([
      [ "2026-07-28", branch.name, actor.full_name, "Cash", "100.00", "REF-2", "SHT-2" ]
    ])

    result = described_class.call(sales_import.id, actor: actor)
    expect(result).to be_ok

    txn = SalesTransaction.find_by(reference_number: "REF-2")
    expect(txn.transaction_date).to eq(Date.new(2026, 7, 28))
    expect(txn.transaction_time).to be_nil
  end
end
