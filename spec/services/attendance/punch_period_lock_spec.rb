require "rails_helper"

# TD-T-1 — device punches and payroll-period finalization coordinate on the
# canonical period row, proven with TWO database connections (a second
# connection is the only thing a row lock can block). Attendance::PunchService
# reads the period FOR SHARE inside one transaction that also writes the
# attendance record and the punch log; Payroll::Approver locks the same row FOR
# UPDATE. Lock order: payroll period → attendance record → punch log.
#
# Deterministic: the operation under test is paused at a known point by a
# blocking Queue handshake (no sleeps); the other connection probes with NOWAIT,
# runs the real finalizer under a short lock_timeout, or is observed waiting in
# pg_locks — every wait is bounded.
#
# Not transactional (the other connection must see committed rows): every
# example refuses to start unless the test database is empty and truncates every
# table afterwards — the harness of spec/services/requests/punch_correction_period_lock_spec.rb.
RSpec.describe "Device punch ↔ payroll period locking (two connections)" do
  self.use_transactional_tests = false

  around { |ex| travel_to(Time.zone.parse("2026-07-15 09:00:00 UTC")) { ex.run } } # 12:00 in Riyadh

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

    # One decision, used both to truncate and to report: the message says SKIPPED
    # exactly when truncation did not run.
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
  # in) and joined again. Returns [threads still alive, exceptions raised].
  #
  # If anything unexpected escapes (an exception outside StandardError), the
  # ensure still kills and joins (bounded) every worker that is alive before the
  # exception propagates — the `after` hook then aborts before truncating, so the
  # database is left untouched and the example fails.
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
  # transaction — the workers' connections and transactions are released.
  def open_connection_problems
    problems = []
    busy = ActiveRecord::Base.connection_pool.stat[:busy]
    problems << "#{busy - 1} worker connection(s) still checked out" if busy > 1

    conn   = ActiveRecord::Base.connection
    others = conn.select_value(<<~SQL).to_i
      SELECT COUNT(*) FROM pg_stat_activity
      WHERE datname = current_database() AND pid <> pg_backend_pid()
        AND state IN ('active', 'idle in transaction', 'idle in transaction (aborted)')
    SQL
    problems << "#{others} other database session(s) still active or in a transaction" if others.positive?
    problems
  end

  let(:business) { create(:business, timezone: "Asia/Riyadh", business_day_start_hour: 6, working_days_per_month: 22) }
  let(:branch)   { create(:branch, business: business) }
  let(:shift)    { create(:shift, :fixed_time, business: business) }
  let(:reviewer) { create(:user, :owner, business: business) }
  let(:employee_a) { employee }
  let(:employee_b) { employee }
  let(:period) do
    create(:payroll_period, business: business, period_year: 2026, period_month: 7, working_days: 22, status: "under_review")
  end

  def employee
    create(:user, business: business, allow_biometric_attendance: true).tap do |user|
      create(:shift_assignment, user: user, branch: branch, shift: shift, effective_from: Date.new(2026, 1, 1))
    end
  end

  def punch(user) = Attendance::PunchService.call(employee: user, punched_at: Time.current, business: business)
  def records_of(user) = AttendanceRecord.where(user_id: user.id).count
  def period_now = PayrollPeriod.find(period.id)

  # Pauses the next call of klass.method (on whichever thread) until released.
  def pause_inside(klass, method)
    reached = Queue.new
    release = Queue.new
    allow(klass).to receive(method).and_wrap_original do |original, *args, **kwargs, &block|
      reached << true
      release.pop
      original.call(*args, **kwargs, &block)
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

  def finalize_with_lock_timeout
    conn = ActiveRecord::Base.connection
    conn.execute("SET lock_timeout = '250ms'")
    Payroll::Approver.advance(period: period_now, by: reviewer)
  ensure
    conn.execute("RESET lock_timeout")
  end

  def expect_period_row_share_locked
    expect { PayrollPeriod.transaction { PayrollPeriod.lock("FOR UPDATE NOWAIT").find(period.id) } }
      .to raise_error(ActiveRecord::LockWaitTimeout)
    expect { PayrollPeriod.transaction { PayrollPeriod.lock("FOR SHARE NOWAIT").find(period.id) } }.not_to raise_error
  end

  # Bounded wait until some backend is blocked on a lock. A row-lock waiter
  # (FOR SHARE behind a FOR UPDATE) waits on the holder's transaction id or the
  # tuple, not on the relation, so any ungranted lock counts — the test database
  # is otherwise idle (empty-database guard). Fails if nothing ever waits. A
  # deadline loop, not Timeout.timeout: an asynchronous Timeout could interrupt
  # the query mid-flight and leave this connection unusable for cleanup.
  def wait_until_a_backend_waits
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
    until ActiveRecord::Base.connection.select_value("SELECT COUNT(*) FROM pg_locks WHERE NOT granted").to_i.positive?
      raise "no backend waited for a lock within 10 s" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      Thread.pass
    end
  end

  # Runs a block on this connection with a PostgreSQL lock_timeout: a blocked
  # lock fails cleanly with ActiveRecord::LockWaitTimeout (never an asynchronous
  # interrupt of the transaction).
  def with_lock_timeout(value = "2s")
    conn = ActiveRecord::Base.connection
    conn.execute("SET lock_timeout = '#{value}'")
    yield
  ensure
    conn.execute("RESET lock_timeout")
  end

  before { reviewer && period }

  it "a punch holds the period row FOR SHARE from its lock check to its commit: finalization cannot run in between" do
    reached, release = pause_inside(Shifts::AssignmentResolver, :for) # right after the period lock
    punching = on_other_connection { punch(employee_a) }
    wait_for(reached)

    expect_period_row_share_locked
    blocked = finalize_with_lock_timeout
    expect(blocked).not_to be_success
    expect(blocked.error).to match(/lock timeout/)
    expect(period_now.status).to eq("under_review")

    release << true
    expect(result_of(punching)).to be_success
    expect(records_of(employee_a)).to eq(1)

    expect(Payroll::Approver.advance(period: period_now, by: reviewer)).to be_success # the row is free again
    expect(period_now.status).to eq("finalized")
  end

  it "a finalization holding the row makes the punch wait; the punch then sees finalized and changes nothing" do
    reached, release = pause_inside(Payroll::EmployerInsuranceCost, :for) # inside Approver's transaction, after FOR UPDATE
    finalizing = on_other_connection { Payroll::Approver.advance(period: period_now, by: reviewer) }
    wait_for(reached)

    punching = on_other_connection { punch(employee_a) }
    wait_until_a_backend_waits
    expect(punching.join(0)).to be_nil # still waiting for the period row

    release << true
    expect(result_of(finalizing)).to be_success

    result = result_of(punching)
    expect(result).not_to be_success
    expect(result.action).to eq("rejected_payroll_locked")
    expect(records_of(employee_a)).to eq(0)
    expect(BiometricPunchLog.where(employee_id: employee_a.id).pluck(:action)).to eq([ "rejected_payroll_locked" ])
  end

  it "two punches of different employees in the same month hold the shared lock at the same time" do
    first_employee  = employee_a
    second_employee = employee_b
    reached, release = pause_inside(Shifts::AssignmentResolver, :for)
    first = on_other_connection { punch(first_employee) }
    wait_for(reached)

    # The first punch holds FOR SHARE; a second punch on this connection is not blocked by it.
    allow(Shifts::AssignmentResolver).to receive(:for).and_call_original
    expect(with_lock_timeout { punch(second_employee) }).to be_success # a FOR UPDATE lock would raise LockWaitTimeout here
    expect(records_of(second_employee)).to eq(1)

    release << true
    expect(result_of(first)).to be_success
    expect(records_of(first_employee)).to eq(1)
  end

  it "rolls the attendance change back when the punch log cannot be written" do
    user = employee_a
    allow(BiometricPunchLog).to receive(:create!).and_raise(ActiveRecord::StatementInvalid, "log insert failed")

    expect { punch(user) }.to raise_error(ActiveRecord::StatementInvalid)

    expect(records_of(user)).to eq(0) # committed state, read on a real (non-transactional) connection
    expect { PayrollPeriod.transaction { PayrollPeriod.lock("FOR UPDATE NOWAIT").find(period.id) } }.not_to raise_error
  end

  it "accepts a punch when the month has no payroll period yet (nothing to lock)" do
    PayrollPeriod.where(id: period.id).delete_all
    user = employee_a

    expect(punch(user)).to be_success
    expect(records_of(user)).to eq(1)
  end
end
