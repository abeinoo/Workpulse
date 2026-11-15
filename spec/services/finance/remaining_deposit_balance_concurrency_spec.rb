require "rails_helper"

# Remaining Deposit Balance (cash shortage) closing operations under real
# concurrency, with TWO database connections (a second connection is the only
# thing a row lock can block): individual settlement
# (Finance::RemainingDepositBalanceSettler), write-off
# (Finance::RemainingDepositBalanceWriteOff) and bulk custody settlement
# (Finance::BulkShortageCustodySettler). All three take the canonical lock order
# — DailyReconciliation row(s) by id, then balance row(s) by id (then, for bulk,
# the custody account) — and re-check the balance under the lock. Every example
# asserts the safe invariant: a balance is closed at most once, never settled
# beyond its amount, and never credited to custody twice.
#
# Deterministic: the first operation is paused (blocking Queue handshake, no
# sleeps) right after its first audit entry — inside its transaction, holding
# its locks, uncommitted — and the second is observed waiting on a lock
# (pg_stat_activity); every wait is bounded.
#
# Not transactional (the other connection must see committed rows): every
# example refuses to start unless the test database is empty and truncates every
# table afterwards — the harness of
# spec/characterization/inventory_purchasing/goods_receipt_payments_concurrency_spec.rb.
RSpec.describe "Remaining Deposit Balance closing — concurrency (two connections)" do
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
    connection_check = ConcurrencyConnectionCheck.call if survivors.empty?
    problems.concat(connection_check.blocking) if connection_check

    truncated = @guard_passed && problems.empty?
    if truncated
      conn = ActiveRecord::Base.connection
      conn.truncate_tables(*self.class.data_tables(conn))
    end

    problems.concat(connection_check.leaks) if connection_check
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

  # Runs the block on its own thread and database connection.
  def on_other_connection(&block)
    Thread.new { ActiveRecord::Base.connection_pool.with_connection(prevent_permanent_checkout: true, &block) }
          .tap { |t| t.report_on_exception = false }
          .tap { |t| (@threads ||= []) << t }
  end

  def wait_for(queue) = Timeout.timeout(10) { queue.pop }
  def result_of(thread) = thread.join(10)&.value || raise("operation did not finish")

  def wait_until_lock_waits(pattern)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
    loop do
      query = ActiveRecord::Base.connection.select_value(<<~SQL)
        SELECT query FROM pg_stat_activity
        WHERE datname = current_database() AND pid <> pg_backend_pid()
          AND wait_event_type = 'Lock' AND query ILIKE #{ActiveRecord::Base.connection.quote(pattern)}
        LIMIT 1
      SQL
      return query if query
      raise "no backend waited on a lock for #{pattern} within 10 s" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      Thread.pass
    end
  end

  # Pauses right after the FIRST AuditLog write — inside the first operation's
  # transaction, after its ledger row and balance update, locks held.
  def pause_after_first_audit
    reached = Queue.new
    release = Queue.new
    calls   = 0
    allow(AuditLog).to receive(:create!).and_wrap_original do |original, *args, **kwargs, &blk|
      calls += 1
      outcome = original.call(*args, **kwargs, &blk)
      if calls == 1
        reached << true
        release.pop
      end
      outcome
    end
    @releases = (@releases || []) << release
    [ reached, release ]
  end

  DR_LOCK = "%daily_reconciliations%FOR UPDATE%".freeze

  let(:business) { create(:business) }
  let(:branch)   { create(:branch, business: business) }

  def user_with(*perms)
    role = business.permission_roles.create!(name: "R-#{SecureRandom.hex(3)}", permissions: perms,
                                             permission_scopes: perms.index_with { "business_wide" })
    create(:user, business: business).tap { |u| u.update_column(:permission_role_id, role.id) }
  end

  let(:actor) do
    user_with("view_daily_reconciliation", "settle_remaining_deposit_balance",
              "view_employee_balances", "manage_employee_balances", "receive_shortage_settlement_cash")
  end
  let!(:cash_pm) { PaymentMethod.create!(business: business, name: "Cash", settlement_type: "cash", active: true) }
  let(:cashier) { create(:user, business: business) }
  let(:account) { create(:custody_account, business: business, user: create(:user, business: business)) }

  def shortage(amount, date: Date.new(2026, 11, 1))
    dr = DailyReconciliation.create!(branch: branch, business: business, state: "closed",
                                     opened_at: date.to_time + 9.hours, closed_at: date.to_time + 22.hours,
                                     business_date: date)
    RemainingDepositBalance.create!(daily_reconciliation: dr, responsible_user: cashier, created_by: actor,
                                    business: business, branch: branch, amount: amount,
                                    remaining_amount: amount, status: "open")
  end

  def settle(id, amount) = Finance::RemainingDepositBalanceSettler.new(id, actor: actor, amount: amount, notes: "paid").call
  def write_off(id) = Finance::RemainingDepositBalanceWriteOff.new(id, actor: actor, notes: "lost").call
  def bulk(dr_ids)
    Finance::BulkShortageCustodySettler.new(daily_reconciliation_ids: dr_ids, custody_account_id: account.id,
                                            actor: actor, notes: "collected").call
  end

  def cash_bulk(dr_ids)
    Finance::BulkShortageCashSettler.new(daily_reconciliation_ids: dr_ids, actor: actor, notes: "paid in cash").call
  end

  def closing_rows(rdb) = RemainingDepositBalanceTransaction.where(remaining_deposit_balance_id: rdb.id)
                                                            .where(transaction_type: %w[settlement write_off])
  def not_open = I18n.t("remaining_deposit_balances.errors.not_open")
  def bulk_already_settled = I18n.t("finance.daily_reconciliations.errors.bulk_settle.already_settled")

  it "write-off first, settlement second: the settlement waits, then is refused — closed once" do
    rdb = shortage(200)
    reached, release = pause_after_first_audit

    writing_off = on_other_connection { write_off(rdb.id) }
    wait_for(reached)

    settling = on_other_connection { settle(rdb.id, 200) }
    expect(wait_until_lock_waits(DR_LOCK)).to be_present
    expect(settling.join(0)).to be_nil

    release << true
    expect(result_of(writing_off)).to be_ok
    refused = result_of(settling)
    expect([ refused.ok?, refused.error ]).to eq([ false, not_open ])

    final = RemainingDepositBalance.find(rdb.id)
    expect([ final.status, final.remaining_amount ]).to eq([ "written_off", 0 ])
    expect(closing_rows(rdb).pluck(:transaction_type)).to eq([ "write_off" ])
  end

  it "settlement first, write-off second: the write-off waits, then is refused" do
    rdb = shortage(200)
    reached, release = pause_after_first_audit

    settling = on_other_connection { settle(rdb.id, 200) }
    wait_for(reached)

    writing_off = on_other_connection { write_off(rdb.id) }
    expect(wait_until_lock_waits(DR_LOCK)).to be_present

    release << true
    expect(result_of(settling)).to be_ok
    refused = result_of(writing_off)
    expect([ refused.ok?, refused.error ]).to eq([ false, not_open ])
    expect(RemainingDepositBalance.find(rdb.id).status).to eq("settled")
    expect(closing_rows(rdb).pluck(:transaction_type)).to eq([ "settlement" ])
  end

  it "two settlements of the full amount: the second waits and is refused — never settled twice" do
    rdb = shortage(200)
    reached, release = pause_after_first_audit

    first = on_other_connection { settle(rdb.id, 200) }
    wait_for(reached)
    second = on_other_connection { settle(rdb.id, 200) }
    expect(wait_until_lock_waits(DR_LOCK)).to be_present

    release << true
    expect(result_of(first)).to be_ok
    expect(result_of(second).error).to eq(not_open)
    expect(closing_rows(rdb).sum(:amount)).to eq(200)
  end

  it "bulk custody settlement first, individual settlement second: refused; one custody credit" do
    rdb = shortage(200)
    reached, release = pause_after_first_audit

    bulking = on_other_connection { bulk([ rdb.daily_reconciliation_id ]) }
    wait_for(reached)

    settling = on_other_connection { settle(rdb.id, 200) }
    expect(wait_until_lock_waits(DR_LOCK)).to be_present

    release << true
    expect(result_of(bulking)).to be_ok
    expect(result_of(settling).error).to eq(not_open)

    rows = closing_rows(rdb).to_a
    expect(rows.size).to eq(1)
    expect(rows.first.custody_transaction_id).to be_present
    expect(CustodyTransaction.where(custody_account_id: account.id).sum(:amount)).to eq(200)
  end

  it "partial settlement first, bulk second: bulk waits and credits only what is still owed" do
    rdb = shortage(200)
    reached, release = pause_after_first_audit

    settling = on_other_connection { settle(rdb.id, 50) }
    wait_for(reached)

    bulking = on_other_connection { bulk([ rdb.daily_reconciliation_id ]) }
    expect(wait_until_lock_waits(DR_LOCK)).to be_present

    release << true
    expect(result_of(settling)).to be_ok
    result = result_of(bulking)
    expect([ result.ok?, result.total ]).to eq([ true, 150 ])

    final = RemainingDepositBalance.find(rdb.id)
    expect([ final.status, final.remaining_amount ]).to eq([ "settled", 0 ])
    expect(closing_rows(rdb).sum(:amount)).to eq(200)
    expect(CustodyTransaction.where(custody_account_id: account.id).sum(:amount)).to eq(150)
  end

  it "write-off first, bulk second: bulk waits, then rejects everything (all-or-nothing)" do
    rdb = shortage(200)
    reached, release = pause_after_first_audit

    writing_off = on_other_connection { write_off(rdb.id) }
    wait_for(reached)

    bulking = on_other_connection { bulk([ rdb.daily_reconciliation_id ]) }
    expect(wait_until_lock_waits(DR_LOCK)).to be_present

    release << true
    expect(result_of(writing_off)).to be_ok
    expect(result_of(bulking).error).to eq(bulk_already_settled)
    expect(CustodyTransaction.count).to eq(0)
  end

  it "two overlapping bulk settlements: the second waits and is refused — one credit per shortage" do
    rdb_a = shortage(100, date: Date.new(2026, 11, 1))
    rdb_b = shortage(150, date: Date.new(2026, 11, 2))
    reached, release = pause_after_first_audit

    first = on_other_connection { bulk([ rdb_a.daily_reconciliation_id, rdb_b.daily_reconciliation_id ]) }
    wait_for(reached)

    second = on_other_connection { bulk([ rdb_b.daily_reconciliation_id, rdb_a.daily_reconciliation_id ]) }
    expect(wait_until_lock_waits(DR_LOCK)).to be_present

    release << true
    expect(result_of(first)).to be_ok
    expect(result_of(second).error).to eq(bulk_already_settled)
    expect(CustodyTransaction.where(custody_account_id: account.id).pluck(:amount)).to contain_exactly(100, 150)
  end

  it "a write-off holding one day does not deadlock a bulk over two days: bulk waits, then rejects all" do
    rdb_a = shortage(100, date: Date.new(2026, 11, 1))
    rdb_b = shortage(150, date: Date.new(2026, 11, 2))
    reached, release = pause_after_first_audit

    writing_off = on_other_connection { write_off(rdb_b.id) }
    wait_for(reached)

    bulking = on_other_connection { bulk([ rdb_b.daily_reconciliation_id, rdb_a.daily_reconciliation_id ]) }
    expect(wait_until_lock_waits(DR_LOCK)).to be_present

    release << true
    expect(result_of(writing_off)).to be_ok
    expect(result_of(bulking).error).to eq(bulk_already_settled)
    expect(RemainingDepositBalance.find(rdb_a.id)).to be_open
    expect(CustodyTransaction.count).to eq(0)
  end

  describe "Receive Cash vs other settlements" do
    it "cash bulk first, custody bulk second: the custody bulk waits, then is refused — no custody credit" do
      rdb = shortage(200)
      reached, release = pause_after_first_audit

      cashing = on_other_connection { cash_bulk([ rdb.daily_reconciliation_id ]) }
      wait_for(reached)

      bulking = on_other_connection { bulk([ rdb.daily_reconciliation_id ]) }
      expect(wait_until_lock_waits(DR_LOCK)).to be_present

      release << true
      expect(result_of(cashing)).to be_ok
      expect(result_of(bulking).error).to eq(bulk_already_settled)
      expect(closing_rows(rdb).pluck(:payment_method_id, :custody_transaction_id)).to eq([ [ cash_pm.id, nil ] ])
      expect(CustodyTransaction.count).to eq(0)
    end

    it "custody bulk first, cash bulk second: the cash bulk waits, then is refused — one settlement" do
      rdb = shortage(200)
      reached, release = pause_after_first_audit

      bulking = on_other_connection { bulk([ rdb.daily_reconciliation_id ]) }
      wait_for(reached)

      cashing = on_other_connection { cash_bulk([ rdb.daily_reconciliation_id ]) }
      expect(wait_until_lock_waits(DR_LOCK)).to be_present

      release << true
      expect(result_of(bulking)).to be_ok
      expect(result_of(cashing).error).to eq(bulk_already_settled)
      rows = closing_rows(rdb).to_a
      expect(rows.size).to eq(1)
      expect([ rows.first.payment_method_id, rows.first.custody_transaction_id.present? ]).to eq([ nil, true ])
    end

    it "cash bulk first, individual settlement second: refused — settled once" do
      rdb = shortage(200)
      reached, release = pause_after_first_audit

      cashing = on_other_connection { cash_bulk([ rdb.daily_reconciliation_id ]) }
      wait_for(reached)

      settling = on_other_connection { settle(rdb.id, 200) }
      expect(wait_until_lock_waits(DR_LOCK)).to be_present

      release << true
      expect(result_of(cashing)).to be_ok
      expect(result_of(settling).error).to eq(not_open)
      expect(closing_rows(rdb).sum(:amount)).to eq(200)
    end

    it "write-off first, cash bulk second: the cash bulk waits, then rejects everything" do
      rdb = shortage(200)
      reached, release = pause_after_first_audit

      writing_off = on_other_connection { write_off(rdb.id) }
      wait_for(reached)

      cashing = on_other_connection { cash_bulk([ rdb.daily_reconciliation_id ]) }
      expect(wait_until_lock_waits(DR_LOCK)).to be_present

      release << true
      expect(result_of(writing_off)).to be_ok
      expect(result_of(cashing).error).to eq(bulk_already_settled)
      expect(closing_rows(rdb).pluck(:transaction_type)).to eq([ "write_off" ])
    end
  end
end
