require "rails_helper"

RSpec.describe Finance::BankStatements::StaleMatchRepair do
  let(:business) { create(:business) }
  let(:branch)   { create(:branch, business: business) }
  let(:actor)    { create(:user, business: business) }
  let(:cash_pm)  { PaymentMethod.create!(business: business, name: "Cash", settlement_type: "cash", active: true) }
  let(:day)      { Time.current.in_time_zone(business.timezone_object).to_date }
  let(:dr) do
    DailyReconciliation.create!(branch: branch, business: business, state: "deposited",
                                opened_at: 1.hour.ago, business_date: day)
  end

  def deposit!(amount)
    TillDeposit.create!(daily_reconciliation: dr, payment_method: cash_pm, deposited_by: actor,
                        amount: amount, deposited_at: Time.current)
  end

  def statement!
    create(:bank_statement, :pending, business: business, branch: branch, statement_from: day - 3, statement_to: day + 3)
  end

  # A match on a statement then deleted WITHOUT releasing it — the legacy state.
  def stale_match!(amount, statement: statement!, line_status: nil)
    dep  = deposit!(amount)
    line = BankStatementTransaction.create!(bank_statement: statement, business: business, amount: amount,
                                            transaction_date: day, raw_data: {}, status: "pending")
    Finance::DepositVerification::MatchingEngine.call(statement.id, actor: actor)
    line.update_columns(status: line_status) if line_status
    statement.update_columns(deleted_at: Time.current)
    DepositMatch.find_by!(bank_statement_transaction_id: line.id)
  end

  subject(:repair) { described_class.new(business: business, actor: actor) }

  def release_audits = AuditLog.where(action: "released_by_statement_deletion")

  it "reports stale matches with their records and a verdict, and changes nothing" do
    match = stale_match!(6_100)
    live  = statement!
    deposit!(300)
    BankStatementTransaction.create!(bank_statement: live, business: business, amount: 300,
                                     transaction_date: day, raw_data: {}, status: "pending")
    Finance::DepositVerification::MatchingEngine.call(live.id, actor: actor) # active match: not stale

    items = nil
    expect { items = repair.report }.not_to(change { [ DepositMatch.count, AuditLog.count ] })

    expect(items.map(&:match_id)).to eq([ match.id ])
    item = items.sole
    expect(item.to_h).to include(transaction_id: match.bank_statement_transaction_id, deposit_id: match.till_deposit_id,
                                 daily_reconciliation_id: dr.id, amount: 6_100, transaction_status: "verified",
                                 verdict: :eligible, reason: nil)
  end

  it "is a dry run unless execute: true" do
    match = stale_match!(6_100)

    outcomes = repair.repair!(match_ids: [ match.id ])

    expect(outcomes.map(&:result)).to eq([ :would_release ])
    expect(DepositMatch.exists?(match.id)).to be true
    expect(release_audits).to be_empty
  end

  it "releases only the named matches, through the shared release step, with a repair audit", :aggregate_failures do
    chosen = stale_match!(6_100)
    other  = stale_match!(300)
    line   = chosen.bank_statement_transaction
    statement = line.bank_statement

    outcomes = repair.repair!(match_ids: [ chosen.id ], execute: true)

    expect(outcomes.map(&:result)).to eq([ :released ])
    expect(DepositMatch.exists?(chosen.id)).to be false
    expect(DepositMatch.exists?(other.id)).to be true
    expect(line.reload.status).to eq("unexpected")
    expect([ statement.reload.matched_rows, statement.unmatched_rows ]).to eq([ 0, 1 ])
    audit = release_audits.sole
    expect(audit.auditable).to eq(line)
    expect(audit.actor).to eq(actor)
    expect(audit.metadata).to include("repair" => true, "till_deposit_id" => chosen.till_deposit_id,
                                      "bank_statement_id" => statement.id)
  end

  it "skips voided deposits, active statements and already-released matches, and reports each", :aggregate_failures do
    voided = stale_match!(100)
    voided.till_deposit.update_columns(voided_at: Time.current, void_reason: "x")
    released = stale_match!(200)
    repair.repair!(match_ids: [ released.id ], execute: true)
    live = statement!
    active = stale_match!(300, statement: live)
    live.update_columns(deleted_at: nil)

    outcomes = repair.repair!(match_ids: [ voided.id, released.id, active.id ], execute: true).index_by(&:match_id)

    expect(outcomes[voided.id].to_h).to include(result: :skipped, reason: "deposit is voided — review the void separately")
    expect(outcomes[released.id].result).to eq(:skipped)
    expect(outcomes[active.id].result).to eq(:skipped)
    expect(DepositMatch.where(id: [ voided.id, active.id ]).count).to eq(2)
    expect(release_audits.count).to eq(1) # only the earlier release
  end

  it "refuses to run without named matches, or to execute without an actor of the business" do
    expect { repair.repair!(match_ids: [], execute: true) }.to raise_error(ArgumentError)
    outsider = described_class.new(business: business, actor: create(:user))
    expect { outsider.repair!(match_ids: [ 1 ], execute: true) }.to raise_error(ArgumentError)
  end

  it "reports a failed release and rolls that record back" do
    match = stale_match!(6_100)
    allow_any_instance_of(Finance::BankStatements::Unmatcher).to receive(:release!)
      .and_raise(ActiveRecord::RecordInvalid, BankStatementTransaction.new)

    outcome = repair.repair!(match_ids: [ match.id ], execute: true).sole

    expect(outcome.result).to eq(:failed)
    expect(DepositMatch.exists?(match.id)).to be true
    expect(release_audits).to be_empty
  end

  it "treats a needs_reverification line (the common restored shape) as eligible and releases it" do
    match = stale_match!(250, line_status: "needs_reverification")

    expect(repair.report.sole.to_h).to include(match_id: match.id, transaction_status: "needs_reverification",
                                               verdict: :eligible)
    expect(repair.repair!(match_ids: [ match.id ], execute: true).sole.result).to eq(:released)
    expect(match.bank_statement_transaction.reload.status).to eq("unexpected")
  end
end
