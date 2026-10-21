require "rails_helper"

# F-A2 — two payments of the same salary advance, proven with TWO database
# connections (a second connection is the only thing a row lock can block).
# Requests::Approver#pay locks the request row (SELECT … FOR UPDATE, F-A1),
# re-checks it is payable and only then marks it paid, creates the Advance
# (Requests::AdvanceEffects → Payroll::AdvanceEffects) and writes the pay audit,
# all in one transaction; Requests::BulkPaymentService runs #pay for each request
# inside one outer transaction, so its locks are held until the batch commits.
# The unique index on advances.employee_request_id is the database backstop.
#
# Deterministic: the first payment is paused (blocking Queue handshake, no
# sleeps) right after its first Advance is created — the request row is locked
# and already paid, nothing committed; the second payment is then observed
# waiting on a lock while running the employee_requests FOR UPDATE
# (pg_stat_activity); every wait is bounded.
#
# Not transactional (the other connection must see committed rows): every
# example refuses to start unless the test database is empty and truncates every
# table afterwards — the harness of spec/services/attendance/punch_period_lock_spec.rb.
# Opposite-order bulk batches (a deadlock, F-A7) are deliberately not covered.
RSpec.describe "Salary advance payment concurrency (two connections, F-A2)" do
  self.use_transactional_tests = false

  def self.data_tables(conn) = conn.tables - %w[schema_migrations ar_internal_metadata]

  # The guard: this example may truncate only a database it found empty.
  # @guard_passed is set only once the check succeeds; RSpec still runs `after`
  # when `before` raises, and then the database is left untouched.
  before do
    @guard_passed = false
    conn  = ActiveRecord::Base.connection
    dirty = self.class.data_tables(conn).select do |table|
      conn.select_value("SELECT EXISTS (SELECT 1 FROM #{conn.quote_table_name(table)})")
    end
    raise "test database not empty (#{dirty.first(5).join(', ')}…): refusing to run a truncating spec" if dirty.any?

    @guard_passed = true
  end

  # Cleanup: release every paused worker, then shut every worker down (bounded),
  # then truncate — but only when the guard passed AND no worker is alive AND no
  # other connection is still checked out or inside a transaction. Otherwise
  # truncation is skipped and the hook fails loudly; it never pretends it cleaned.
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

  # Joins every worker; a worker's exception (re-raised by #join) is captured, never
  # allowed to skip the others. A worker still alive after the bounded join is
  # killed (its ensure blocks roll its transaction back and check its connection
  # in) and joined again; an unexpected escape still kills and joins the rest.
  # Returns [threads still alive, exceptions raised].
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

  # With every worker dead, only this example's own connection may be checked
  # out, and no other backend of the test database may be active or inside a
  # transaction.
  def open_connection_problems
    problems = []
    busy = ActiveRecord::Base.connection_pool.stat[:busy]
    problems << "#{busy - 1} worker connection(s) still checked out" if busy > 1

    others = ActiveRecord::Base.connection.select_value(<<~SQL).to_i
      SELECT COUNT(*) FROM pg_stat_activity
      WHERE datname = current_database() AND pid <> pg_backend_pid()
        AND state IN ('active', 'idle in transaction', 'idle in transaction (aborted)')
        AND backend_type = 'client backend' -- not autovacuum or other PostgreSQL background workers
    SQL
    problems << "#{others} other database session(s) still active or in a transaction" if others.positive?
    problems
  end

  let(:business)   { create(:business) }
  let(:accountant) { create(:user, :accountant, business: business) }
  let(:other_payer) { create(:user, :accountant, business: business) }

  def approved_advance(amount)
    create(:employee_request, :salary_advance, :approved, amount: amount, user: create(:user, business: business))
  end

  # Each operation loads its own copy (as a controller would) on its own connection.
  def pay(request_id, by: accountant) = Requests::Approver.pay(request: EmployeeRequest.find(request_id), paid_by: by)

  def bulk_pay(ids, by: accountant)
    Requests::BulkPaymentService.call(requests: ids.map { |id| EmployeeRequest.includes(:user, :advance).find(id) },
                                      paid_by: by, notes: "batch")
  end

  # Pauses the FIRST Advance creation (after it ran: the request row is locked,
  # marked paid and has its Advance, uncommitted) until released; later calls run
  # straight through.
  def pause_after_first_advance
    reached = Queue.new
    release = Queue.new
    calls   = 0
    allow(Payroll::AdvanceEffects).to receive(:advance_paid).and_wrap_original do |original, **kwargs|
      calls += 1
      outcome = original.call(**kwargs)
      if calls == 1
        reached << true
        release.pop
      end
      outcome
    end
    @releases = (@releases || []) << release
    [ reached, release ]
  end

  # Runs the block on its own thread and database connection.
  def on_other_connection(&block)
    Thread.new { ActiveRecord::Base.connection_pool.with_connection(&block) }
          .tap { |t| t.report_on_exception = false }
          .tap { |t| (@threads ||= []) << t }
  end

  def wait_for(queue) = Timeout.timeout(10) { queue.pop }
  def result_of(thread) = thread.join(10)&.value || raise("operation did not finish")

  # Bounded wait until another backend is blocked on a lock while running the
  # request-row FOR UPDATE (Approver#pay's lock!). A deadline loop, not
  # Timeout.timeout around a query. Returns the waiting statement.
  def wait_until_request_lock_waits
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
    loop do
      query = ActiveRecord::Base.connection.select_value(<<~SQL)
        SELECT query FROM pg_stat_activity
        WHERE datname = current_database() AND pid <> pg_backend_pid()
          AND wait_event_type = 'Lock' AND query ILIKE '%employee_requests%FOR UPDATE%'
        LIMIT 1
      SQL
      return query if query
      raise "no backend waited for the request row lock within 10 s" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      Thread.pass
    end
  end

  def advances_of(request) = Advance.where(employee_request_id: request.id).count
  def pay_audits_of(request) = AuditLog.where(auditable_type: "EmployeeRequest", auditable_id: request.id, action: "pay").count
  def bulk_audits = AuditLog.where(action: "bulk_pay_advances")
  def status_of(request) = EmployeeRequest.find(request.id).status

  it "single vs single: the second payment waits for the row lock, then is refused — one Advance, one pay audit" do
    request = approved_advance(1_500.0)
    reached, release = pause_after_first_advance

    first = on_other_connection { pay(request.id) }
    wait_for(reached) # locked, paid and its Advance created — not committed

    second = on_other_connection { pay(request.id, by: other_payer) }
    expect(wait_until_request_lock_waits).to match(/FOR UPDATE/)
    expect(second.join(0)).to be_nil

    release << true
    expect(result_of(first)).to be_success

    refused = result_of(second)
    expect(refused).not_to be_success
    expect(refused.error).to eq(Requests::Approver::NOT_PAYABLE)

    expect(status_of(request)).to eq("paid")
    expect(advances_of(request)).to eq(1)
    expect(Advance.find_by!(employee_request_id: request.id).total_amount).to eq(1_500)
    expect(pay_audits_of(request)).to eq(1)
    expect(EmployeeRequest.find(request.id).reviewed_by_id).to eq(accountant.id)
  end

  it "bulk vs single: the single payment waits for the batch's lock, then is refused — the batch's payment stands" do
    request   = approved_advance(1_000.0)
    unrelated = approved_advance(700.0)
    reached, release = pause_after_first_advance

    batch = on_other_connection { bulk_pay([ request.id ]) }
    wait_for(reached)

    single = on_other_connection { pay(request.id, by: other_payer) }
    wait_until_request_lock_waits
    expect(single.join(0)).to be_nil

    release << true
    bulk = result_of(batch)
    expect(bulk.paid.map(&:id)).to eq([ request.id ])
    expect(bulk.skipped).to be_empty

    refused = result_of(single)
    expect(refused).not_to be_success
    expect(refused.error).to eq(Requests::Approver::NOT_PAYABLE)

    expect(status_of(request)).to eq("paid")
    expect(advances_of(request)).to eq(1)
    expect(pay_audits_of(request)).to eq(1)
    expect(bulk_audits.count).to eq(1)
    expect(bulk_audits.first.metadata).to include("request_ids" => [ request.id ], "request_count" => 1)

    expect(status_of(unrelated)).to eq("approved")
    expect(advances_of(unrelated)).to eq(0)
  end

  it "two batches with the same first lock: the second waits, skips the paid request and pays its own" do
    r1 = approved_advance(1_000.0)
    r2 = approved_advance(2_000.0)
    r3 = approved_advance(3_000.0)
    reached, release = pause_after_first_advance

    batch_a = on_other_connection { bulk_pay([ r1.id, r2.id ]) }
    wait_for(reached) # holds r1 (paid, Advance created), not committed

    batch_b = on_other_connection { bulk_pay([ r1.id, r3.id ], by: other_payer) }
    wait_until_request_lock_waits
    expect(batch_b.join(0)).to be_nil

    release << true
    a = result_of(batch_a)
    b = result_of(batch_b)

    expect(a.paid.map(&:id)).to eq([ r1.id, r2.id ])
    expect(a.skipped).to be_empty
    expect(b.paid.map(&:id)).to eq([ r3.id ])
    expect(b.skipped.map { |s| [ s.request.id, s.reason ] }).to eq([ [ r1.id, Requests::Approver::NOT_PAYABLE ] ])

    [ r1, r2, r3 ].each do |request|
      expect(status_of(request)).to eq("paid")
      expect(advances_of(request)).to eq(1)
      expect(pay_audits_of(request)).to eq(1)
    end
    expect(Advance.count).to eq(3)
    expect(EmployeeRequest.find(r1.id).reviewed_by_id).to eq(accountant.id) # batch A's payment, not overwritten

    expect(bulk_audits.count).to eq(2)
    expect(bulk_audits.map { |log| [ log.actor_id, log.metadata["request_ids"] ] })
      .to contain_exactly([ accountant.id, [ r1.id, r2.id ] ], [ other_payer.id, [ r3.id ] ])
  end

  # F-A7: from this (main) connection, may the row be locked right now? NOWAIT —
  # a row held by another transaction raises at once instead of waiting.
  def row_free?(request)
    EmployeeRequest.transaction { EmployeeRequest.lock("FOR UPDATE NOWAIT").find(request.id) }
    true
  rescue ActiveRecord::LockWaitTimeout
    false
  end

  it "opposite-order batches: ascending-id locking makes the second wait on r1 holding nothing — no deadlock (F-A7)" do
    r1 = approved_advance(1_000.0)
    r2 = approved_advance(2_000.0)
    r3 = approved_advance(3_000.0)
    reached, release = pause_after_first_advance

    batch_a = on_other_connection { bulk_pay([ r1.id, r2.id ]) }
    wait_for(reached) # holds r1 (paid, Advance created), not committed; r2 not locked yet

    batch_b = on_other_connection { bulk_pay([ r3.id, r2.id, r1.id ], by: other_payer) } # reversed selection
    wait_until_request_lock_waits
    expect(batch_b.join(0)).to be_nil

    # B waits on r1 without having locked r2 or r3 first (input order would lock r3, r2, then wait for r1).
    expect(row_free?(r1)).to be false
    expect(row_free?(r2)).to be true
    expect(row_free?(r3)).to be true

    release << true
    a = result_of(batch_a) # a deadlock would raise ActiveRecord::Deadlocked from one of these joins
    b = result_of(batch_b)

    expect(a.paid.map(&:id)).to eq([ r1.id, r2.id ])
    expect(b.paid.map(&:id)).to eq([ r3.id ])
    expect(b.skipped.map { |s| [ s.request.id, s.reason ] })
      .to eq([ [ r1.id, Requests::Approver::NOT_PAYABLE ], [ r2.id, Requests::Approver::NOT_PAYABLE ] ])

    [ r1, r2, r3 ].each do |request|
      expect(status_of(request)).to eq("paid")
      expect(advances_of(request)).to eq(1)
      expect(pay_audits_of(request)).to eq(1)
    end
    expect(Advance.count).to eq(3)
    expect(EmployeeRequest.where(id: [ r1.id, r2.id ]).pluck(:reviewed_by_id).uniq).to eq([ accountant.id ])

    expect(bulk_audits.map { |log| [ log.actor_id, log.metadata["request_ids"] ] })
      .to contain_exactly([ accountant.id, [ r1.id, r2.id ] ], [ other_payer.id, [ r3.id ] ])
  end
end
