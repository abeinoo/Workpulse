require "rails_helper"

# Regression coverage for auto-applying an imported POS refund as a real
# Finance::TillRefund — so it actually reduces Expected Cash / settlement,
# not just the Sales Verification comparison display. See
# Finance::SalesImports::Importer#apply_auto_refunds!.
RSpec.describe "Finance::SalesImports::Importer — auto-refund propagation" do
  let(:business) { create(:business) }
  let(:branch)   { create(:branch, business: business) }
  let(:actor)    { create(:user, :owner, business: business) }
  let(:cashier)  { create(:user, business: business, first_name: "Ahmed", last_name: "Bahaa") }
  let!(:cash_pm) { PaymentMethod.create!(business: business, name: "Cash", settlement_type: "cash", active: true) }
  let!(:visa_pm) { PaymentMethod.create!(business: business, name: "Visa", settlement_type: "card", active: true) }

  let!(:dr) do
    DailyReconciliation.create!(
      branch: branch, business: business, state: "open",
      opened_at: 1.hour.ago, business_date: Date.new(2026, 7, 28)
    )
  end
  let!(:till_session) { TillSession.create!(daily_reconciliation: dr, current_holder: cashier) }

  let(:column_mapping) do
    {
      "transaction_date"    => "Date",
      "branch_name"         => "Branch",
      "cashier_name"        => "Cashier",
      "payment_method_name" => "Method",
      "amount"              => "Amount",
      "reference_number"    => "Ref",
      "transaction_type"    => "Type"
    }
  end
  let(:headers) { %w[Date Branch Cashier Method Amount Ref Type] }

  def sales_import_with_rows(rows)
    csv = CSV.generate do |c|
      c << headers
      rows.each { |r| c << r }
    end
    sales_import = SalesImport.create!(business: business, imported_by: actor, file_name: "export.csv",
                                       status: "column_mapped", column_mapping: column_mapping)
    sales_import.file.attach(io: StringIO.new(csv), filename: "export.csv", content_type: "text/csv")
    sales_import
  end

  def close_day!(cash_collected: 2099, cash_refund_typed: 0)
    Finance::TillHandoverCreator.new(
      actor: cashier, daily_reconciliation_id: dr.id,
      params: { self_deposit: "1", depositor_type: "self",
                amounts: { cash_pm.id.to_s => { collected_amount: cash_collected.to_s, refund_amount: cash_refund_typed.to_s } } }
    ).call
  end

  it "auto-creates a TillRefund for a cash refund, and it actually reduces Expected Cash after close" do
    sales_import = sales_import_with_rows([
      [ "28 Jul 2026", branch.name, cashier.full_name, "Cash", "2000.00", "REF-CASH-1", "Refund" ]
    ])

    result = Finance::SalesImports::Importer.call(sales_import.id, actor: actor)
    expect(result).to be_ok

    refund = TillRefund.find_by(daily_reconciliation: dr)
    expect(refund).to be_present
    expect(refund.amount).to eq(2000)
    expect(refund.payment_method).to eq(cash_pm)
    expect(refund.processed_by).to eq(cashier)

    close_result = close_day!(cash_collected: 2099, cash_refund_typed: 0)
    expect(close_result.ok?).to be(true), close_result.error

    session_amount = dr.reload.session_amounts.find_by(payment_method: cash_pm)
    expect(session_amount.refund_amount).to eq(2000)
    expect(dr.expected_cash_deposit).to eq(99)
  end

  it "does NOT reduce cash for a Visa (non-cash) refund — only the matching payment method is affected" do
    sales_import = sales_import_with_rows([
      [ "28 Jul 2026", branch.name, cashier.full_name, "Visa", "2000.00", "REF-VISA-1", "Refund" ]
    ])

    Finance::SalesImports::Importer.call(sales_import.id, actor: actor)

    refund = TillRefund.find_by(daily_reconciliation: dr)
    expect(refund.payment_method).to eq(visa_pm)

    close_result = close_day!(cash_collected: 2099, cash_refund_typed: 0)
    expect(close_result.ok?).to be(true), close_result.error

    expect(dr.reload.expected_cash_deposit).to eq(2099) # unaffected by the Visa refund
    visa_session_amount = dr.session_amounts.find_by(payment_method: visa_pm)
    expect(visa_session_amount).to be_nil # no Visa handover amount was ever recorded — the refund alone doesn't fabricate one
  end

  it "does not duplicate the TillRefund when the same file is re-imported (stable idempotency key)" do
    rows = [ [ "28 Jul 2026", branch.name, cashier.full_name, "Cash", "500.00", "REF-DUP-1", "Refund" ] ]
    sales_import = sales_import_with_rows(rows)

    Finance::SalesImports::Importer.call(sales_import.id, actor: actor)
    expect(TillRefund.where(daily_reconciliation: dr).count).to eq(1)

    # Re-run the same import (delete_all + reinsert fresh SalesTransaction rows
    # with new ids, but the SAME reference_number).
    sales_import.update!(status: "column_mapped")
    Finance::SalesImports::Importer.call(sales_import.id, actor: actor)

    expect(TillRefund.where(daily_reconciliation: dr).count).to eq(1)
    expect(TillRefund.where(daily_reconciliation: dr).sum(:amount)).to eq(500)
  end

  it "does not auto-apply (and does not fail the import) when the Daily Reconciliation is no longer open" do
    dr.update!(state: "closed", closed_at: Time.current)
    sales_import = sales_import_with_rows([
      [ "28 Jul 2026", branch.name, cashier.full_name, "Cash", "300.00", "REF-CLOSED-1", "Refund" ]
    ])

    result = Finance::SalesImports::Importer.call(sales_import.id, actor: actor)

    expect(result).to be_ok
    expect(SalesTransaction.find_by(reference_number: "REF-CLOSED-1")).to be_present
    expect(TillRefund.where(daily_reconciliation: dr)).to be_empty
  end

  it "imports the refund as a comparison record but does not auto-apply it when there is no stable reference/transaction id" do
    sales_import = sales_import_with_rows([
      [ "28 Jul 2026", branch.name, cashier.full_name, "Cash", "150.00", "", "Refund" ]
    ])

    result = Finance::SalesImports::Importer.call(sales_import.id, actor: actor)

    expect(result).to be_ok
    expect(SalesTransaction.where(daily_reconciliation: dr, transaction_type: "refund").count).to eq(1)
    expect(TillRefund.where(daily_reconciliation: dr)).to be_empty
  end

  it "skips auto-apply when the cashier name matches more than one employee (ambiguous)" do
    create(:user, business: business, first_name: "Ahmed", last_name: "Bahaa")
    sales_import = sales_import_with_rows([
      [ "28 Jul 2026", branch.name, "Ahmed Bahaa", "Cash", "80.00", "REF-AMBIG-1", "Refund" ]
    ])

    result = Finance::SalesImports::Importer.call(sales_import.id, actor: actor)

    expect(result).to be_ok
    expect(TillRefund.where(daily_reconciliation: dr)).to be_empty
  end

  it "does not auto-create anything for an ordinary sale row" do
    sales_import = sales_import_with_rows([
      [ "28 Jul 2026", branch.name, cashier.full_name, "Cash", "500.00", "REF-SALE-1", "Sale" ]
    ])

    Finance::SalesImports::Importer.call(sales_import.id, actor: actor)

    expect(TillRefund.where(daily_reconciliation: dr)).to be_empty
  end

  it "leaves an audit trail on the sales_import for auto-applied refunds" do
    sales_import = sales_import_with_rows([
      [ "28 Jul 2026", branch.name, cashier.full_name, "Cash", "60.00", "REF-AUDIT-1", "Refund" ]
    ])

    Finance::SalesImports::Importer.call(sales_import.id, actor: actor)

    log = AuditLog.where(auditable: sales_import, action: "auto_refunds_applied").first
    expect(log).to be_present
    expect(log.metadata["created"]).to eq(1)

    refund = TillRefund.find_by(daily_reconciliation: dr)
    refund_log = AuditLog.where(auditable: refund, action: "create").first
    expect(refund_log).to be_present
    expect(refund_log.actor).to eq(cashier)
  end
end
