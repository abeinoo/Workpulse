require "rails_helper"

RSpec.describe Finance::BankStatements::Deleter do
  let(:business) { create(:business) }
  let(:branch)   { create(:branch, business: business) }
  let(:actor)    { create(:user, business: business) }
  let(:cash_pm)  { PaymentMethod.create!(business: business, name: "Cash", settlement_type: "cash", active: true) }
  let(:day)      { Time.current.in_time_zone(business.timezone_object).to_date }

  let(:dr) do
    DailyReconciliation.create!(branch: branch, business: business, state: "deposited",
                                opened_at: 1.hour.ago, business_date: day)
  end

  def statement!
    create(:bank_statement, :pending, business: business, branch: branch, statement_from: day - 3, statement_to: day + 3)
  end

  def deposit!(amount)
    TillDeposit.create!(daily_reconciliation: dr, payment_method: cash_pm, deposited_by: actor,
                        amount: amount, deposited_at: Time.current)
  end

  def line!(statement, amount, status: "pending")
    BankStatementTransaction.create!(bank_statement: statement, business: business, amount: amount,
                                     transaction_date: day, raw_data: {}, status: status)
  end

  def auto_match!(statement, rematch: false)
    Finance::DepositVerification::MatchingEngine.call(statement.id, actor: actor, rematch: rematch)
  end

  def delete!(statement, notes: "Wrong file uploaded")
    described_class.call(statement.id, actor: actor, notes: notes)
  end

  def release_audits = AuditLog.where(action: "released_by_statement_deletion")

  def expect_counters_match_rows!(statement)
    statement.reload
    txns = statement.bank_statement_transactions
    expect(statement.matched_rows).to eq(txns.where.associated(:deposit_matches).count)
    expect(statement.unmatched_rows).to eq(txns.where.missing(:deposit_matches).where.not(status: "ignored").count)
  end

  it "releases the statement's match, keeps the transaction, and soft-deletes", :aggregate_failures do
    st  = statement!
    dep = deposit!(6_100)
    txn = line!(st, 6_100)
    auto_match!(st)
    expect(txn.reload.matched_till_deposit).to eq(dep)

    result = delete!(st)

    expect(result).to be_ok
    expect(result.released_count).to eq(1)
    st.reload
    expect(st).to be_deleted
    expect([ st.deleted_by_id, st.deletion_notes ]).to eq([ actor.id, "Wrong file uploaded" ])
    txn.reload
    expect(txn.status).to eq("unexpected")
    expect(txn.deposit_matches).to be_empty
    expect(dep.reload.deposit_matches).to be_empty
    expect_counters_match_rows!(st)

    audit = release_audits.sole
    expect(audit.auditable).to eq(txn)
    expect(audit.metadata).to include("bank_statement_id" => st.id, "till_deposit_id" => dep.id,
                                      "previous_till_deposit_id" => dep.id, "deletion_notes" => "Wrong file uploaded")
    deletion = AuditLog.where(auditable: st, action: "bank_statement_deleted").sole
    expect(deletion.metadata).to include("released_matches" => 1, "matched_rows" => 1, "notes" => "Wrong file uploaded")
  end

  it "releases every match on this statement and leaves another active statement's matches alone", :aggregate_failures do
    st, other = statement!, statement!
    a, b, kept = deposit!(100), deposit!(200), deposit!(300)
    line_a, line_b = line!(st, 100), line!(st, 200)
    unmatched_line = line!(st, 999)
    kept_line = line!(other, 300)
    auto_match!(st)
    auto_match!(other)
    expect(kept_line.reload.matched_till_deposit).to eq(kept)
    unmatched_status = unmatched_line.reload.status

    result = delete!(st)

    expect(result.released_count).to eq(2)
    expect([ line_a, line_b ].map { |t| t.reload.deposit_matches.count }).to eq([ 0, 0 ])
    expect(unmatched_line.reload.status).to eq(unmatched_status) # untouched: it held no match
    expect(kept_line.reload.matched_till_deposit).to eq(kept)
    expect(kept_line.status).to eq("verified")
    expect(release_audits.pluck(:auditable_id)).to contain_exactly(line_a.id, line_b.id)
    expect([ a, b ].map { |d| d.reload.deposit_matches.count }).to eq([ 0, 0 ])
    expect_counters_match_rows!(st)
    expect_counters_match_rows!(other)
  end

  it "deletes a statement with no matches safely" do
    st = statement!
    line!(st, 50)
    auto_match!(st)

    result = delete!(st)

    expect(result).to be_ok
    expect(result.released_count).to eq(0)
    expect(st.reload).to be_deleted
    expect(release_audits).to be_empty
    expect(AuditLog.where(auditable: st, action: "bank_statement_deleted").count).to eq(1)
  end

  it "rolls back every release and the deletion when one release fails", :aggregate_failures do
    st = statement!
    deposit!(100)
    deposit!(200)
    line!(st, 100)
    line!(st, 200)
    auto_match!(st)
    calls = 0
    allow_any_instance_of(Finance::BankStatements::Unmatcher).to receive(:release!).and_wrap_original do |original, *args, **kwargs|
      calls += 1
      raise ActiveRecord::RecordInvalid, BankStatementTransaction.new if calls == 2

      original.call(*args, **kwargs)
    end

    result = delete!(st)

    expect(result).not_to be_ok
    st.reload
    expect(st).not_to be_deleted
    expect(DepositMatch.joins(:bank_statement_transaction)
                      .where(bank_statement_transactions: { bank_statement_id: st.id }).count).to eq(2)
    expect(st.bank_statement_transactions.pluck(:status).uniq).to eq([ "verified" ])
    expect([ st.matched_rows, st.unmatched_rows ]).to eq([ 2, 0 ])
    expect(release_audits).to be_empty
    expect(AuditLog.where(auditable: st, action: "bank_statement_deleted")).to be_empty
  end

  it "succeeds on retry after a failure, and refuses a second deletion without new audit rows", :aggregate_failures do
    st = statement!
    deposit!(100)
    line!(st, 100)
    auto_match!(st)
    allow_any_instance_of(Finance::BankStatements::Unmatcher).to receive(:release!)
      .and_raise(ActiveRecord::RecordInvalid, BankStatementTransaction.new)
    expect(delete!(st)).not_to be_ok
    RSpec::Mocks.space.proxy_for(Finance::BankStatements::Unmatcher).reset
    allow_any_instance_of(Finance::BankStatements::Unmatcher).to receive(:release!).and_call_original

    expect(delete!(st)).to be_ok
    again = delete!(st)

    expect(again).not_to be_ok
    expect(again.error).to eq(I18n.t("finance.bank_statements.errors.already_deleted"))
    expect(release_audits.count).to eq(1)
    expect(AuditLog.where(auditable: st, action: "bank_statement_deleted").count).to eq(1)
    expect_counters_match_rows!(st)
  end

  it "makes the released deposit eligible for the same bank movement on another statement", :aggregate_failures do
    old_statement = statement!
    dep = deposit!(6_100)
    line!(old_statement, 6_100)
    auto_match!(old_statement)

    reimport = statement!
    new_line = line!(reimport, 6_100)
    auto_match!(reimport)
    # Still linked through the old statement: reported for review, not stolen.
    expect(new_line.reload.status).to eq("needs_manual_review")
    expect(new_line.deposit_matches).to be_empty

    delete!(old_statement)
    # Deletion releases only — it never matches anything by itself.
    expect(new_line.reload.deposit_matches).to be_empty

    auto_match!(reimport, rematch: true)
    expect(new_line.reload.matched_till_deposit).to eq(dep)
    expect(new_line.status).to eq("verified")
  end

  # The real stale shapes: 19 of the 22 restored stale matches sat on lines a
  # POS import had flipped to needs_reverification; manual matches must be
  # released the same way.
  it "releases matches whatever the line's status or match method", :aggregate_failures do
    st = statement!
    invalidated = deposit!(100)
    manual      = deposit!(200)
    reverif_line = line!(st, 100)
    manual_line  = line!(st, 200, status: "unexpected")
    auto_match!(st)
    reverif_line.update_columns(status: "needs_reverification")
    Finance::BankStatements::ManualMatcher.call(manual_line.id, till_deposit_id: manual.id, actor: actor, notes: "slip #9")
    expect(manual_line.reload.match_method).to eq("manual")

    result = delete!(st)

    expect(result.released_count).to eq(2)
    expect([ reverif_line, manual_line ].map { |t| t.reload.deposit_matches.count }).to eq([ 0, 0 ])
    expect([ invalidated, manual ].map { |d| d.reload.match_status }).to eq(%i[unmatched unmatched])
    expect(release_audits.pluck(:auditable_id)).to contain_exactly(reverif_line.id, manual_line.id)
    expect_counters_match_rows!(st)
  end

  it "cannot release legacy matches by deleting an already-deleted statement again" do
    st = statement!
    deposit!(100)
    line!(st, 100)
    auto_match!(st)
    st.update_columns(deleted_at: Time.current) # legacy soft delete without release

    expect(delete!(st)).not_to be_ok
    expect(DepositMatch.joins(:bank_statement_transaction)
                      .where(bank_statement_transactions: { bank_statement_id: st.id }).count).to eq(1)
  end

  # BUG-003: releases are fail-closed (Unmatcher#release!). The first release is
  # written, the second cannot be audited: everything rolls back, including the
  # first release and its entry.
  it "deletes and releases nothing when one release cannot be audited (fail-closed)", :aggregate_failures do
    st = statement!
    dep_a, dep_b = deposit!(100), deposit!(200)
    txn_a, txn_b = line!(st, 100), line!(st, 200)
    auto_match!(st)
    expect([ txn_a.reload.matched_till_deposit, txn_b.reload.matched_till_deposit ]).to eq([ dep_a, dep_b ])
    fail_audit_writes!(:released_by_statement_deletion, skip: 1)

    result = delete!(st)

    expect(result).not_to be_ok
    expect(result.error).to eq(I18n.t("audit_log.errors.write_failed"))
    expect(result.released_count).to eq(0)
    expect(st.reload).not_to be_deleted
    expect([ txn_a.reload.matched_till_deposit, txn_b.reload.matched_till_deposit ]).to eq([ dep_a, dep_b ])
    expect(st.matched_rows).to eq(2)
    expect(release_audits).to be_empty
    expect(AuditLog.where(auditable: st, action: "bank_statement_deleted")).to be_empty
  end
end
