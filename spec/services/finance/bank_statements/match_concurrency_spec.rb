require "rails_helper"

# Competing bank-match operations proven with TWO database connections (a second
# connection is the only thing a row lock or a unique index can block). The first
# operation is paused (blocking Queue handshake, no sleeps) inside its transaction,
# the second is started and observed waiting in Postgres (pg_stat_activity), and
# then the first is released. Each example asserts the SAFE outcome:
#   * the same bank transaction is never linked to two deposits
#     (unique index on deposit_matches.bank_statement_transaction_id);
#   * a voided deposit never ends up holding a match, whichever side wins
#     (TillDepositVoider, ManualMatcher and MatchingEngine all row-lock the deposit).
#
# Not transactional (the other connection must see committed rows): every
# example refuses to start unless the test database is empty and truncates every
# table afterwards — the harness of spec/services/inventory/document_voider_concurrency_spec.rb.
RSpec.describe "Bank statement match concurrency (two connections)" do
  self.use_transactional_tests = false

  def self.data_tables(conn) = conn.tables - %w[schema_migrations ar_internal_metadata]

  before do
    @guard_passed = false
    conn  = ActiveRecord::Base.connection
    dirty = self.class.data_tables(conn).select do |table|
      conn.select_value("SELECT EXISTS (SELECT 1 FROM #{conn.quote_table_name(table)})")
    end
    raise "test database not empty (#{dirty.first(5).join(', ')}…): refusing to run a truncating spec" if dirty.any?

    @guard_passed = true
  end

  after do
    (@releases || []).each { |release| 2.times { release << true } }
    survivors, worker_errors = shut_down_workers

    problems = []
    problems << "worker thread(s) still alive after shutdown: #{survivors.map(&:inspect).join(', ')}" if survivors.any?
    problems.concat(open_connection_problems) if survivors.empty?

    truncated = @guard_passed && problems.empty?
    if truncated
      conn = ActiveRecord::Base.connection
      conn.truncate_tables(*self.class.data_tables(conn))
    end

    problems.concat(worker_errors.map { |error| "worker raised #{error.class}: #{error.message}" })
    raise "concurrency cleanup: #{problems.join('; ')}#{' — truncation SKIPPED' unless truncated}" if problems.any?
  end

  def shut_down_workers
    errors  = []
    threads = @threads || []
    join = lambda do |thread, seconds|
      thread.join(seconds)
    rescue StandardError => e
      errors << e
      thread
    end

    completed = false
    begin
      survivors = threads.reject { |thread| join.call(thread, 10) }
      survivors.each(&:kill)
      survivors = survivors.reject { |thread| join.call(thread, 5) }
      completed = true
    ensure
      threads.select(&:alive?).each { |thread| thread.kill && join.call(thread, 5) } unless completed
    end
    [ survivors, errors ]
  end

  def open_connection_problems
    problems = []
    busy = ActiveRecord::Base.connection_pool.stat[:busy]
    problems << "#{busy - 1} worker connection(s) still checked out" if busy > 1

    others = ActiveRecord::Base.connection.select_value(<<~SQL).to_i
      SELECT COUNT(*) FROM pg_stat_activity
      WHERE datname = current_database() AND pid <> pg_backend_pid()
        AND state IN ('active', 'idle in transaction', 'idle in transaction (aborted)')
        AND backend_type = 'client backend'
    SQL
    problems << "#{others} other database session(s) still active or in a transaction" if others.positive?
    problems
  end

  def on_other_connection(&block)
    Thread.new { ActiveRecord::Base.connection_pool.with_connection(&block) }
          .tap { |t| t.report_on_exception = false }
          .tap { |t| (@threads ||= []) << t }
  end

  def wait_for(queue) = Timeout.timeout(10) { queue.pop }
  def result_of(thread) = thread.join(10)&.value || raise("operation did not finish")

  # Bounded wait until another backend is blocked on a lock while running a
  # statement on `table`. Returns the waiting statement.
  def wait_until_lock_waits(table)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
    loop do
      query = ActiveRecord::Base.connection.select_value(<<~SQL)
        SELECT query FROM pg_stat_activity
        WHERE datname = current_database() AND pid <> pg_backend_pid()
          AND wait_event_type = 'Lock' AND query ILIKE #{ActiveRecord::Base.connection.quote("%#{table}%")}
        LIMIT 1
      SQL
      return query if query
      raise "no backend waited on a lock for #{table} within 10 s" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      Thread.pass
    end
  end

  # Pauses the first call of `method` on `target` (after the original ran, so
  # its writes and locks are held, uncommitted) until released.
  def pause_after_first(target, method, any_instance: false)
    reached = Queue.new
    release = Queue.new
    calls   = 0
    stub = any_instance ? allow_any_instance_of(target) : allow(target)
    stub.to receive(method).and_wrap_original do |original, *args, **kwargs|
      value = original.call(*args, **kwargs)
      calls += 1
      if calls == 1
        reached << true
        release.pop
      end
      value
    end
    @releases = (@releases || []) << release
    [ reached, release ]
  end

  let(:business) { create(:business) }
  let(:branch)   { create(:branch, business: business) }
  let(:first_user)  { create(:user, business: business) }
  let(:second_user) { create(:user, business: business) }
  let(:cash_pm) { PaymentMethod.create!(business: business, name: "Cash", settlement_type: "cash", active: true) }
  let(:day)     { Time.current.in_time_zone(business.timezone_object).to_date }

  let(:dr) do
    DailyReconciliation.create!(branch: branch, business: business, state: "deposited",
                                opened_at: 1.hour.ago, closed_at: Time.current, business_date: day)
  end

  let(:statement) do
    create(:bank_statement, :pending, business: business, branch: branch, statement_from: day, statement_to: day)
  end

  def deposit!
    TillDeposit.create!(daily_reconciliation: dr, payment_method: cash_pm, deposited_by: first_user,
                        amount: 6_100, deposited_at: Time.current)
  end

  def bank_line!(status: "unexpected")
    BankStatementTransaction.create!(bank_statement: statement, business: business, amount: 6_100,
                                     transaction_date: day, raw_data: {}, status: status)
  end

  def set_counters!
    txns = statement.bank_statement_transactions
    statement.update_columns(matched_rows: txns.where.associated(:deposit_matches).count,
                             unmatched_rows: txns.where.missing(:deposit_matches).count)
  end

  def manual_match(txn_id, deposit_id, user)
    Finance::BankStatements::ManualMatcher.call(txn_id, till_deposit_id: deposit_id, actor: User.find(user.id),
                                                notes: "confirmed")
  end

  def void(deposit_id, user)
    Finance::TillDepositVoider.new(deposit_id, actor: User.find(user.id), void_reason: "wrong slip").call
  end

  def expect_counters_match_rows!
    statement.reload
    txns = statement.bank_statement_transactions
    expect(statement.matched_rows).to eq(txns.where.associated(:deposit_matches).count)
    expect(statement.unmatched_rows).to eq(txns.where.missing(:deposit_matches).count)
  end

  def expect_single_match!(txn, winner, loser_result)
    expect(loser_result).not_to be_ok
    expect(loser_result.error).to eq(I18n.t("finance.bank_statements.errors.already_matched_to_another_deposit"))
    expect(DepositMatch.where(bank_statement_transaction_id: txn.id).pluck(:till_deposit_id)).to eq([ winner.id ])
    expect(AuditLog.where(auditable_type: "BankStatementTransaction", auditable_id: txn.id,
                          action: "manual_match").count).to eq(1)
    expect(txn.reload.status).to eq("verified")
    expect_counters_match_rows!
  end

  # Deposits in two different DRs: no shared row lock, so the only guard left is
  # the unique index — the second INSERT blocks on the first's uncommitted row
  # and fails with a unique violation once it commits.
  it "two manual matches of one bank transaction to deposits in different DRs: the unique index lets exactly one win",
     :aggregate_failures do
    other_branch = create(:branch, business: business)
    other_dr = DailyReconciliation.create!(branch: other_branch, business: business, state: "deposited",
                                           opened_at: 1.hour.ago, closed_at: Time.current, business_date: day)
    deposit_a = deposit!
    deposit_b = TillDeposit.create!(daily_reconciliation: other_dr, payment_method: cash_pm, deposited_by: first_user,
                                    amount: 6_100, deposited_at: Time.current)
    txn = bank_line!
    set_counters!

    reached, release = pause_after_first(DepositMatch, :create_for!)
    first = on_other_connection { manual_match(txn.id, deposit_a.id, first_user) }
    wait_for(reached) # match row inserted for deposit A — not committed

    second = on_other_connection { manual_match(txn.id, deposit_b.id, second_user) }
    expect(wait_until_lock_waits("deposit_matches")).to include("INSERT")
    expect(second.join(0)).to be_nil

    release << true
    expect(result_of(first)).to be_ok
    expect_single_match!(txn, deposit_a, result_of(second))
  end

  # Deposits in the same DR: ManualMatcher's FOR UPDATE over the deposit/DR join
  # locks the shared DR row, so the second matcher queues there and its
  # already-matched re-check (run after the lock) refuses.
  it "two manual matches of one bank transaction to deposits in the same DR: the second queues and is refused",
     :aggregate_failures do
    deposit_a = deposit!
    deposit_b = deposit!
    txn = bank_line!
    set_counters!

    reached, release = pause_after_first(DepositMatch, :create_for!)
    first = on_other_connection { manual_match(txn.id, deposit_a.id, first_user) }
    wait_for(reached)

    second = on_other_connection { manual_match(txn.id, deposit_b.id, second_user) }
    expect(wait_until_lock_waits("till_deposits")).to include("FOR UPDATE")
    expect(second.join(0)).to be_nil

    release << true
    expect(result_of(first)).to be_ok
    expect_single_match!(txn, deposit_a, result_of(second))
  end

  it "void commits first: a concurrent manual match to the voided deposit is refused", :aggregate_failures do
    target = deposit!
    txn = bank_line!
    set_counters!

    reached, release = pause_after_first(Finance::TillDepositVoider, :revert_deposited_state!, any_instance: true)
    voiding = on_other_connection { void(target.id, first_user) }
    wait_for(reached) # deposit locked and voided — not committed

    matching = on_other_connection { manual_match(txn.id, target.id, second_user) }
    expect(wait_until_lock_waits("till_deposits")).to be_present
    expect(matching.join(0)).to be_nil

    release << true
    expect(result_of(voiding)).to be_ok
    expect(result_of(matching)).not_to be_ok

    expect(target.reload).to be_voided
    expect(DepositMatch.where(till_deposit_id: target.id)).to be_empty
    expect(txn.reload.status).to eq("unexpected")
    expect_counters_match_rows!
  end

  it "manual match commits first: the concurrent void then releases that match", :aggregate_failures do
    target = deposit!
    txn = bank_line!
    set_counters!

    reached, release = pause_after_first(DepositMatch, :create_for!)
    matching = on_other_connection { manual_match(txn.id, target.id, first_user) }
    wait_for(reached) # deposit (and its DR) locked, match inserted — not committed

    voiding = on_other_connection { void(target.id, second_user) }
    expect(wait_until_lock_waits("daily_reconciliations")).to be_present
    expect(voiding.join(0)).to be_nil

    release << true
    expect(result_of(matching)).to be_ok
    expect(result_of(voiding)).to be_ok

    expect(target.reload).to be_voided
    expect(DepositMatch.where(till_deposit_id: target.id)).to be_empty
    txn.reload
    expect(txn.status).to eq("unexpected")
    expect(AuditLog.where(auditable: txn, action: "manual_match").count).to eq(1)
    expect(AuditLog.where(auditable: txn, action: "released_by_deposit_void").count).to eq(1)
    expect_counters_match_rows!
  end

  it "void commits first: a concurrent automatic match skips the voided deposit", :aggregate_failures do
    target = deposit!
    txn = bank_line!(status: "pending")

    reached, release = pause_after_first(Finance::TillDepositVoider, :revert_deposited_state!, any_instance: true)
    voiding = on_other_connection { void(target.id, first_user) }
    wait_for(reached) # deposit locked and voided — not committed; still active to other readers

    engine = on_other_connection do
      Finance::DepositVerification::MatchingEngine.call(statement.id, actor: User.find(second_user.id))
    end
    expect(wait_until_lock_waits("till_deposits")).to be_present
    expect(engine.join(0)).to be_nil

    release << true
    expect(result_of(voiding)).to be_ok
    expect(result_of(engine)).to be_ok

    expect(DepositMatch.where(till_deposit_id: target.id)).to be_empty
    expect(txn.reload.matched_till_deposit).to be_nil
    expect(txn.status).not_to eq("verified")
    expect_counters_match_rows!
  end
end
