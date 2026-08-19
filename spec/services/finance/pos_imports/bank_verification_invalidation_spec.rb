require "rails_helper"

RSpec.describe Finance::PosImports::Importer, "invalidating stale bank verification" do
  let(:business) { create(:business) }
  let(:actor)    { create(:user, business: business) }
  let(:branch)   { create(:branch, business: business) }
  let(:cash_pm)  { PaymentMethod.create!(business: business, name: "Cash", settlement_type: "cash", active: true) }

  before { create(:pos_terminal, business: business, branch: branch, terminal_id: "TERM-A") }

  def headers
    [ "Transaction ID", "Order ID", "Gross Amount", "Payment Method", "Status",
      "Created At", "Paid At", "Fees", "Administrative Fees", "Product / Order Name",
      "Terminal ID", "Terminal Branch Name", "Branch ID", "Branch Name" ]
  end

  def data_row(transaction_id:, amount: "100.00", terminal_id: "TERM-A", paid_at: "2026-07-16 09:05:00")
    [ transaction_id, "ORD-#{transaction_id}", amount, "Card", "Success", "2026-07-16 09:00:00", paid_at,
      "0", "0", "Service", terminal_id, "Ignored Terminal Branch", "999", "Ignored Branch Name" ]
  end

  def pos_import_with_rows(rows)
    pos_import = create(:pos_import, business: business, imported_by: actor, status: "pending")
    bytes = XlsxBuilder.build([ headers ] + rows)
    pos_import.file.attach(io: StringIO.new(bytes), filename: "export.xlsx")
    pos_import
  end

  # Business day for the DR is treated as the transactions' own calendar
  # date — see PosTransaction.for_calendar_date's comment — so a DR with
  # business_date 2026-07-16 is the one every row above lands in.
  let(:dr) do
    DailyReconciliation.create!(
      branch: branch, business: business, state: "deposited",
      opened_at: 1.hour.ago, closed_at: Time.current, business_date: Date.new(2026, 7, 16)
      )
  end
  let!(:till_session) { TillSession.create!(daily_reconciliation: dr, depositor_id: actor.id) }

  def collect_cash!(amount)
    TillSessionAmount.create!(daily_reconciliation: dr, payment_method: cash_pm,
                              payment_method_name: cash_pm.name, collected_amount: amount, refund_amount: 0)
  end

  def deposit!(amount:)
    TillDeposit.create!(daily_reconciliation: dr, payment_method: cash_pm, deposited_by: actor,
                        amount: amount, deposited_at: Time.zone.local(2026, 7, 16, 14, 0, 0))
  end

  def statement
    create(:bank_statement, business: business, branch: branch,
           statement_from: Date.new(2026, 7, 16), statement_to: Date.new(2026, 7, 16))
  end

  def txn(stmt, amount:)
    BankStatementTransaction.create!(bank_statement: stmt, business: business,
                                     transaction_date: Date.new(2026, 7, 16), amount: amount,
                                     raw_data: {}, status: "unexpected")
  end

  def link!(dep, transaction)
    DepositMatch.create_for!(till_deposit: dep, bank_statement_transaction: transaction, matched_by: actor)
    transaction.update!(status: "verified", match_method: "manual")
  end

  def fully_match_dr!
    collect_cash!(500)
    dep = deposit!(amount: 500)
    matched_txn = txn(statement, amount: 500)
    link!(dep, matched_txn)
    matched_txn
  end

  it "flags the matched bank transaction needs_reverification when a fresh POS import lands new rows for the same branch/date" do
    matched_txn = fully_match_dr!
    expect(dr.bank_reconciliation_status).to eq("completed")

    pos_import = pos_import_with_rows([ data_row(transaction_id: "TXN-1") ])
    result = Time.use_zone(business.timezone_object) { described_class.call(pos_import.id, actor: actor) }

    expect(result).to be_ok
    expect(matched_txn.reload.status).to eq("needs_reverification")
    expect(dr.reload.bank_reconciliation_status).to eq("needs_review")
  end

  it "clears an already-verified DR back to deposited, revoking verified_at/verified_by" do
    fully_match_dr!
    dr.update!(state: "verified", verified_by: actor, verified_at: 1.minute.ago)

    pos_import = pos_import_with_rows([ data_row(transaction_id: "TXN-1") ])
    Time.use_zone(business.timezone_object) { described_class.call(pos_import.id, actor: actor) }

    dr.reload
    expect(dr.verified?).to be false
    expect(dr.state).to eq("deposited")
  end

  it "does not invalidate anything when the import adds no genuinely new rows (all duplicates)" do
    matched_txn = fully_match_dr!
    create(:pos_transaction, business: business, branch: branch, transaction_id: "TXN-1",
           transaction_date: Time.zone.local(2026, 7, 16, 9, 5, 0))

    pos_import = pos_import_with_rows([ data_row(transaction_id: "TXN-1") ])
    result = Time.use_zone(business.timezone_object) { described_class.call(pos_import.id, actor: actor) }

    expect(result).to be_ok
    expect(pos_import.reload.duplicate_rows).to eq(1)
    expect(matched_txn.reload.status).to eq("verified")
  end

  it "does not invalidate a DR in a different branch even on the same calendar date" do
    other_branch = create(:branch, business: business)
    other_dr = DailyReconciliation.create!(
      branch: other_branch, business: business, state: "deposited",
      opened_at: 1.hour.ago, closed_at: Time.current, business_date: Date.new(2026, 7, 16)
      )
    TillSession.create!(daily_reconciliation: other_dr, depositor_id: actor.id)
    matched_txn = fully_match_dr!

    pos_import = pos_import_with_rows([ data_row(transaction_id: "TXN-1") ])
    Time.use_zone(business.timezone_object) { described_class.call(pos_import.id, actor: actor) }

    expect(matched_txn.reload.status).to eq("needs_reverification")
    expect(other_dr.reload.verified?).to be false
  end

  it "does not rerun MatchingEngine — the flagged transaction stays needs_reverification, not re-matched" do
    fully_match_dr!
    expect(Finance::DepositVerification::MatchingEngine).not_to receive(:call)

    pos_import = pos_import_with_rows([ data_row(transaction_id: "TXN-1") ])
    Time.use_zone(business.timezone_object) { described_class.call(pos_import.id, actor: actor) }
  end
end
