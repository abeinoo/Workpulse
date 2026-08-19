require "rails_helper"

RSpec.describe DailyReconciliation, "#bank_reconciliation_status" do
  let(:business) { create(:business) }
  let(:branch)   { create(:branch, business: business) }
  let(:actor)    { create(:user, business: business) }
  let(:cash_pm)  { PaymentMethod.create!(business: business, name: "Cash", settlement_type: "cash", active: true) }
  let(:card_pm)  { PaymentMethod.create!(business: business, name: "Card", settlement_type: "card", active: true) }

  let(:dr) do
    DailyReconciliation.create!(
      branch: branch, business: business, state: "closed",
      opened_at: 1.hour.ago, closed_at: Time.current, business_date: Date.new(2026, 7, 16)
      )
  end
  let!(:till_session) { TillSession.create!(daily_reconciliation: dr, depositor_id: actor.id) }

  def collect_cash!(amount)
    TillSessionAmount.create!(daily_reconciliation: dr, payment_method: cash_pm,
                              payment_method_name: cash_pm.name, collected_amount: amount, refund_amount: 0)
  end

  def deposit(amount:, deposited_at: Time.zone.local(2026, 7, 16, 14, 0, 0), voided: false)
    d = TillDeposit.create!(daily_reconciliation: dr, payment_method: cash_pm, deposited_by: actor,
                            amount: amount, deposited_at: deposited_at)
    d.update!(voided_at: Time.current, voided_by: actor, void_reason: "test") if voided
    d
  end

  def statement(from: Date.new(2026, 7, 16), to: Date.new(2026, 7, 16))
    create(:bank_statement, business: business, branch: branch, statement_from: from, statement_to: to)
  end

  def txn(stmt, amount:, status: "unexpected", transaction_date: Date.new(2026, 7, 16))
    BankStatementTransaction.create!(bank_statement: stmt, business: business, transaction_date: transaction_date,
                                     amount: amount, raw_data: {}, status: status)
  end

  def link!(dep, transaction)
    DepositMatch.create_for!(till_deposit: dep, bank_statement_transaction: transaction, matched_by: actor)
    transaction.update!(status: "verified", match_method: "manual")
  end

  it "returns no_bank_transactions when there's no cash collected at all, even if other conditions differ" do
    expect(dr.expected_cash_deposit).to eq(0)
    expect(dr.bank_reconciliation_status).to eq("no_bank_transactions")
  end

  it "returns waiting_for_deposit when cash is expected but no active deposit exists" do
    collect_cash!(500)
    expect(dr.bank_reconciliation_status).to eq("waiting_for_deposit")
  end

  it "returns waiting_for_deposit when the only deposit is voided (ignores voided deposits)" do
    collect_cash!(500)
    deposit(amount: 500, voided: true)

    expect(dr.bank_reconciliation_status).to eq("waiting_for_deposit")
  end

  it "returns waiting_for_bank_statement when a deposit exists but no statement covers its date" do
    collect_cash!(500)
    deposit(amount: 500)

    expect(dr.bank_reconciliation_status).to eq("waiting_for_bank_statement")
  end

  it "returns waiting_for_matching when a covering statement exists but no matching has been performed" do
    collect_cash!(500)
    deposit(amount: 500)
    statement
    expect(dr.bank_reconciliation_status).to eq("waiting_for_matching")
  end

  it "returns needs_review when a linked transaction was flagged needs_reverification" do
    collect_cash!(500)
    dep = deposit(amount: 500)
    stmt = statement
    transaction = txn(stmt, amount: 500)
    link!(dep, transaction)
    transaction.update!(status: "needs_reverification")

    expect(dr.bank_reconciliation_status).to eq("needs_review")
  end

  it "returns needs_review when an unmatched candidate transaction in range is needs_manual_review" do
    collect_cash!(500)
    deposit(amount: 500)
    stmt = statement
    txn(stmt, amount: 500, status: "needs_manual_review")

    expect(dr.bank_reconciliation_status).to eq("needs_review")
  end

  it "returns difference_found when a matched transaction carries an amount_mismatch status" do
    collect_cash!(500)
    dep = deposit(amount: 500)
    stmt = statement
    transaction = txn(stmt, amount: 480)
    link!(dep, transaction)
    transaction.update!(status: "amount_mismatch")

    expect(dr.bank_reconciliation_status).to eq("difference_found")
  end

  it "returns difference_found when a deposit is over-matched" do
    collect_cash!(500)
    dep = deposit(amount: 500)
    stmt = statement
    link!(dep, txn(stmt, amount: 300))
    link!(dep, txn(stmt, amount: 300))

    expect(dep.reload.match_status).to eq(:over_matched)
    expect(dr.bank_reconciliation_status).to eq("difference_found")
  end

  it "returns partially_matched when one of two deposits is fully matched and the other is not" do
    collect_cash!(1_000)
    dep_a = deposit(amount: 500)
    dep_b = deposit(amount: 500)
    stmt = statement
    link!(dep_a, txn(stmt, amount: 500))

    expect(dr.bank_reconciliation_status).to eq("partially_matched")
    expect(dr.bank_reconciliation_deposits_matched_count).to eq(1)
    expect(dr.bank_reconciliation_deposits_total_count).to eq(2)
  end

  it "returns partially_matched for a single deposit that only received part of its expected amount" do
    collect_cash!(500)
    dep = deposit(amount: 500)
    stmt = statement
    link!(dep, txn(stmt, amount: 300))

    expect(dr.bank_reconciliation_status).to eq("partially_matched")
  end

  it "returns completed when every active deposit is fully matched with no differences" do
    collect_cash!(1_000)
    dep_a = deposit(amount: 500)
    dep_b = deposit(amount: 500)
    stmt = statement
    link!(dep_a, txn(stmt, amount: 500))
    link!(dep_b, txn(stmt, amount: 500))

    expect(dr.bank_reconciliation_status).to eq("completed")
    expect(dr.bank_reconciliation_deposits_matched_count).to eq(2)
    expect(dr.bank_reconciliation_deposits_total_count).to eq(2)
  end

  it "ignores a voided deposit entirely even when an active deposit is fully matched" do
    collect_cash!(500)
    dep = deposit(amount: 500)
    deposit(amount: 9_999, voided: true)
    stmt = statement
    link!(dep, txn(stmt, amount: 500))

    expect(dr.bank_reconciliation_status).to eq("completed")
    expect(dr.bank_reconciliation_deposits_total_count).to eq(1)
  end

  describe "a matched deposit must never coexist with waiting_for_bank_statement" do
    # Regression: Finance::BankStatements::ManualMatcher explicitly allows
    # linking a deposit to a bank transaction whose own statement date range
    # does NOT include the deposit's date (e.g. "the bank processed it after
    # midnight"). bank_statement_covers_deposits? is a pure date-range
    # heuristic and has no way to know this match exists — without the
    # already-matched override, a fully-matched DR would show
    # waiting_for_bank_statement forever, even at 1/1 matched deposits.
    it "returns completed, not waiting_for_bank_statement, when matched via a statement outside the coverage range" do
      collect_cash!(500)
      dep = deposit(amount: 500, deposited_at: Time.zone.local(2026, 7, 16, 14, 0, 0))
      # Statement's own range doesn't include July 16 at all.
      stmt = statement(from: Date.new(2026, 6, 1), to: Date.new(2026, 6, 10))
      link!(dep, txn(stmt, amount: 500, transaction_date: Date.new(2026, 6, 5)))

      expect(dep.reload.match_status).to eq(:fully_matched)
      expect(dr.bank_reconciliation_status).to eq("completed")
      expect(dr.bank_reconciliation_deposits_matched_count).to eq(1)
      expect(dr.bank_reconciliation_deposits_total_count).to eq(1)
    end

    it "returns partially_matched (not waiting_for_bank_statement) when only some deposits are matched this way" do
      collect_cash!(1_000)
      dep_a = deposit(amount: 500, deposited_at: Time.zone.local(2026, 7, 16, 14, 0, 0))
      deposit(amount: 500, deposited_at: Time.zone.local(2026, 7, 16, 15, 0, 0))
      stmt = statement(from: Date.new(2026, 6, 1), to: Date.new(2026, 6, 10))
      link!(dep_a, txn(stmt, amount: 500, transaction_date: Date.new(2026, 6, 5)))

      expect(dr.bank_reconciliation_status).to eq("partially_matched")
    end

    it "still reports waiting_for_bank_statement when nothing is matched yet, even with an out-of-range statement present" do
      collect_cash!(500)
      deposit(amount: 500, deposited_at: Time.zone.local(2026, 7, 16, 14, 0, 0))
      statement(from: Date.new(2026, 6, 1), to: Date.new(2026, 6, 10))

      expect(dr.bank_reconciliation_status).to eq("waiting_for_bank_statement")
    end

    it "#bank_statement_imported? is also true once a deposit is matched, even outside the coverage range" do
      collect_cash!(500)
      dep = deposit(amount: 500, deposited_at: Time.zone.local(2026, 7, 16, 14, 0, 0))
      stmt = statement(from: Date.new(2026, 6, 1), to: Date.new(2026, 6, 10))
      link!(dep, txn(stmt, amount: 500, transaction_date: Date.new(2026, 6, 5)))

      expect(dr.bank_statement_imported?).to be true
    end
  end

  describe "priority ordering" do
    it "no_bank_transactions wins over everything else" do
      # No cash collected, yet other signals (if they existed) would suggest difference_found —
      # highest priority must still short-circuit before any deposit/statement logic runs.
      expect(dr.expected_cash_deposit).to eq(0)
      expect(dr.bank_reconciliation_status).to eq("no_bank_transactions")
    end

    it "waiting_for_bank_statement wins over needs_review/difference_found when there's no coverage" do
      collect_cash!(500)
      deposit(amount: 500)
      # No statement created at all — even though nothing else can be checked yet,
      # this must resolve to waiting_for_bank_statement, not fall through further.
      expect(dr.bank_reconciliation_status).to eq("waiting_for_bank_statement")
    end

    it "needs_review wins over difference_found when both conditions are present" do
      collect_cash!(1_000)
      dep_a = deposit(amount: 500)
      dep_b = deposit(amount: 500)
      stmt = statement
      # dep_a has a genuine difference...
      mismatched = txn(stmt, amount: 480)
      link!(dep_a, mismatched)
      mismatched.update!(status: "amount_mismatch")
      # ...but an unrelated ambiguous candidate also exists in range, which outranks it.
      txn(stmt, amount: 500, status: "needs_manual_review")
      link!(dep_b, txn(stmt, amount: 500))

      expect(dr.bank_reconciliation_status).to eq("needs_review")
    end
  end

  describe "index-page preloaded-array parity" do
    it "produces the same result whether querying live or given a preloaded array" do
      collect_cash!(500)
      dep = deposit(amount: 500)
      stmt = statement
      link!(dep, txn(stmt, amount: 500))

      live = dr.bank_reconciliation_status
      preloaded = dr.bank_reconciliation_status(
        covering_statements: BankStatement.where(business_id: business.id).active.completed.to_a,
        review_transactions: BankStatementTransaction.where(status: "needs_manual_review").to_a
      )

      expect(live).to eq(preloaded)
      expect(live).to eq("completed")
    end
  end

  describe "#total_matched_amount" do
    it "sums matched_total across every active deposit, ignoring voided ones" do
      collect_cash!(1_000)
      dep_a = deposit(amount: 500)
      dep_b = deposit(amount: 500)
      deposit(amount: 9_999, voided: true)
      stmt = statement
      link!(dep_a, txn(stmt, amount: 500))
      link!(dep_b, txn(stmt, amount: 300))

      expect(dr.total_matched_amount).to eq(800)
    end

    it "is zero when nothing has been matched yet" do
      collect_cash!(500)
      deposit(amount: 500)

      expect(dr.total_matched_amount).to eq(0)
    end
  end

  describe "#bank_statement_imported?" do
    it "is false with no active deposits" do
      expect(dr.bank_statement_imported?).to be false
    end

    it "is false when deposits exist but no statement covers them" do
      collect_cash!(500)
      deposit(amount: 500)

      expect(dr.bank_statement_imported?).to be false
    end

    it "is true once a covering statement exists" do
      collect_cash!(500)
      deposit(amount: 500)
      statement

      expect(dr.bank_statement_imported?).to be true
    end

    it "matches a preloaded array the same as a live query" do
      collect_cash!(500)
      deposit(amount: 500)
      statement

      expect(dr.bank_statement_imported?(
        covering_statements: BankStatement.where(business_id: business.id).active.completed.to_a
      )).to be true
    end
  end
end
