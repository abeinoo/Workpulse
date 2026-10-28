require "rails_helper"

RSpec.describe Finance::BankStatements::BulkIgnorer do
  let(:business) { create(:business) }
  let(:branch)   { create(:branch, business: business) }
  let(:actor)    { create(:user, business: business) }
  let(:cash_pm)  { PaymentMethod.create!(business: business, name: "Cash", settlement_type: "cash", active: true) }
  let(:day)      { Time.current.in_time_zone(business.timezone_object).to_date }
  let(:statement) do
    create(:bank_statement, :pending, business: business, branch: branch, statement_from: day - 3, statement_to: day + 3)
  end

  def line!(amount, status: "unexpected", statement: self.statement)
    BankStatementTransaction.create!(bank_statement: statement, business: business, amount: amount,
                                     transaction_date: day, raw_data: {}, status: status)
  end

  def matched_line!(amount)
    dr  = DailyReconciliation.create!(branch: branch, business: business, state: "deposited",
                                      opened_at: 1.hour.ago, business_date: day)
    dep = TillDeposit.create!(daily_reconciliation: dr, payment_method: cash_pm, deposited_by: actor,
                              amount: amount, deposited_at: Time.current)
    line = line!(amount)
    Finance::BankStatements::ManualMatcher.call(line.id, till_deposit_id: dep.id, actor: actor, notes: "slip")
    line.reload
  end

  def counters!
    txns = statement.bank_statement_transactions
    statement.update_columns(matched_rows: txns.where.associated(:deposit_matches).count,
                             unmatched_rows: txns.where.missing(:deposit_matches).where.not(status: "ignored").count)
  end

  def run(ids, reason: "Old bank fees before go-live", actor: self.actor)
    described_class.new(transaction_ids: ids, actor: actor, reason: reason).call
  end

  it "ignores every eligible line, auditing each with the reason and the batch tag", :aggregate_failures do
    lines = [ line!(10), line!(20, status: "amount_mismatch"), line!(30, status: "date_mismatch"),
              line!(40, status: "needs_manual_review") ]
    counters!

    result = run(lines.map(&:id))

    expect(result).to be_ok
    expect(result.ignored_count).to eq(4)
    lines.each(&:reload)
    expect(lines.map(&:status).uniq).to eq([ "ignored" ])
    expect(lines.map(&:ignored_reason).uniq).to eq([ "Old bank fees before go-live" ])
    audits = AuditLog.where(auditable_type: "BankStatementTransaction", auditable_id: lines.map(&:id), action: "ignored")
    expect(audits.count).to eq(4)
    expect(audits.map(&:actor_id).uniq).to eq([ actor.id ])
    expect(audits.map(&:metadata)).to all(include("reason" => "Old bank fees before go-live", "bulk" => true,
                                                  "batch_size" => 4, "was_matched" => false))
    expect([ statement.reload.matched_rows, statement.unmatched_rows ]).to eq([ 0, 0 ])
  end

  it "refuses the whole batch when one line is linked to a deposit, leaving the match intact", :aggregate_failures do
    free    = line!(10)
    matched = matched_line!(250)
    counters!

    result = run([ free.id, matched.id ])

    expect(result).not_to be_ok
    expect(result.error).to include("##{matched.id}")
    expect(free.reload.status).to eq("unexpected")
    expect(matched.reload.status).to eq("verified")
    expect(matched.deposit_matches.count).to eq(1)
    expect(AuditLog.where(action: "ignored")).to be_empty
  end

  it "refuses already-ignored lines and lines of a deleted statement" do
    ignored = line!(10, status: "ignored")
    other   = create(:bank_statement, :pending, business: business, branch: branch,
                     statement_from: day - 3, statement_to: day + 3)
    on_deleted = line!(20, statement: other)
    other.update_columns(deleted_at: Time.current)

    expect(run([ ignored.id ])).not_to be_ok
    expect(run([ on_deleted.id ])).not_to be_ok
    expect(on_deleted.reload.status).to eq("unexpected")
  end

  it "refuses verified and needs_reverification statuses even without a link" do
    expect(run([ line!(10, status: "verified").id ])).not_to be_ok
    expect(run([ line!(20, status: "needs_reverification").id ])).not_to be_ok
  end

  it "treats a repeated submission as already processed: no change, no new audit" do
    line = line!(10)
    expect(run([ line.id ])).to be_ok

    expect { expect(run([ line.id ])).not_to be_ok }.not_to(change { AuditLog.count })
  end

  it "refuses unknown ids and another business's lines without touching anything", :aggregate_failures do
    line = line!(10)
    foreign = create(:business)
    foreign_line = BankStatementTransaction.create!(
      bank_statement: create(:bank_statement, :pending, business: foreign), business: foreign,
      amount: 10, transaction_date: day, raw_data: {}, status: "unexpected"
    )

    expect(run([ line.id, 0, "x", -5 ])).to be_ok # junk ids are dropped, never looked up
    expect(run([ foreign_line.id ]).error).to eq(I18n.t("finance.bank_statements.errors.bulk_ignore_unavailable"))
    expect(run([ 999_999_999 ]).error).to eq(I18n.t("finance.bank_statements.errors.bulk_ignore_unavailable"))
    expect(foreign_line.reload.status).to eq("unexpected")
  end

  it "requires a reason, a selection, and at most MAX_TRANSACTIONS", :aggregate_failures do
    line = line!(10)
    expect(run([ line.id ], reason: "  ").error).to eq(I18n.t("finance.bank_statements.errors.bulk_ignore_reason_required"))
    expect(run([]).error).to eq(I18n.t("finance.bank_statements.errors.bulk_ignore_none_selected"))
    too_many = (1..(described_class::MAX_TRANSACTIONS + 1)).to_a
    expect(run(too_many).error).to eq(I18n.t("finance.bank_statements.errors.bulk_ignore_too_many",
                                             max: described_class::MAX_TRANSACTIONS))
    expect(line.reload.status).to eq("unexpected")
  end

  it "rolls back every ignore when one fails mid-batch" do
    a = line!(10)
    b = line!(20)
    calls = 0
    allow(Finance::BankStatements::Ignorer).to receive(:call).and_wrap_original do |original, *args, **kwargs|
      calls += 1
      raise ActiveRecord::RecordInvalid, BankStatementTransaction.new if calls == 2

      original.call(*args, **kwargs)
    end

    expect(run([ a.id, b.id ])).not_to be_ok
    expect([ a.reload.status, b.reload.status ]).to eq(%w[unexpected unexpected])
    expect(AuditLog.where(action: "ignored")).to be_empty
  end

  # BUG-003: each line goes through Ignorer; bulk-eligible lines are unmatched,
  # so their entries are fail-open. A failed entry inside the batch transaction
  # (middle and last line) neither aborts the batch nor reports a false
  # success: every line is ignored, and only the first line's entry exists.
  it "ignores the whole batch when some audit entries cannot be written (fail-open)", :aggregate_failures do
    lines = [ line!(10), line!(20), line!(30) ]
    counters!
    fail_audit_writes!(:ignored, skip: 1)

    result = run(lines.map(&:id))

    expect(result).to be_ok
    expect(result.ignored_count).to eq(3)
    expect(lines.map { |line| line.reload.status }.uniq).to eq([ "ignored" ])
    expect(statement.reload.unmatched_rows).to eq(0)
    audited = AuditLog.where(auditable_type: "BankStatementTransaction", auditable_id: lines.map(&:id), action: "ignored")
    expect(audited.pluck(:auditable_id)).to eq([ lines.first.id ])
  end
end
