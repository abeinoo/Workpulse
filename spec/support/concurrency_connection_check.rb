# BUG-024 — the connection check the two-connection concurrency specs run in
# their `after` hook, once every worker thread has been joined, to decide
# whether truncating is safe. Each spec keeps its own guard, worker shutdown,
# truncation and error message; only this check is shared, so it is tested once
# (spec/test_infrastructure/concurrency_connection_check_spec.rb).
#
#   check = ConcurrencyConnectionCheck.call
#   check.blocking # truncating now is unsafe: report, skip truncation, fail
#   check.leaks    # a genuine leak: report and fail, but truncation is safe
#
# * A connection still leased by a thread that has exited is a leak (the
#   worker's lease was never returned). It is reported, then handed back
#   through the pool's own `reap` — the same steal/reset/check-in the Rails
#   pool reaper would perform — so it cannot later look busy or be blamed on
#   the next example. Its session holds no transaction afterwards, so it does
#   not block truncation.
# * A connection leased by another live thread, or another database session
#   that is active or inside a transaction, blocks truncation. The Rails pool
#   reaper ("AR Pool Reaper", every 20 s) leases connections for a few
#   milliseconds while it resets or pings them, so the check waits up to
#   `wait` seconds for these to clear before reporting them.
#
# Never terminates a database session and never touches a thread.
module ConcurrencyConnectionCheck
  DEFAULT_WAIT = 2.0
  POLL_INTERVAL = 0.02
  BACKTRACE_LINES = 5
  QUERY_CHARS = 200

  Result = Struct.new(:blocking, :leaks, keyword_init: true)

  module_function

  def call(pool: ActiveRecord::Base.connection_pool, wait: DEFAULT_WAIT, example: RSpec.current_example)
    me     = ActiveSupport::IsolatedExecutionState.context
    leaked = leased_owners(pool).reject { |owner| owner.alive? }
    leaks  = leaked.any? ? [ leak_report(pool, leaked, example) ] : []
    pool.reap if leaked.any?

    deadline = monotonic_now + wait
    loop do
      busy     = leased_owners(pool).select { |owner| owner.alive? && !owner.equal?(me) }
      sessions = other_sessions(pool)
      return Result.new(blocking: [], leaks: leaks) if busy.empty? && sessions.empty?
      if monotonic_now >= deadline
        return Result.new(blocking: [ blocking_report(pool, busy, sessions, wait, example) ], leaks: leaks)
      end

      sleep POLL_INTERVAL
    end
  end

  # The owner thread of every leased connection, read once: a connection can be
  # checked in at any moment, so reports use this snapshot, never conn.owner again.
  def leased_owners(pool)
    pool.connections.filter_map(&:owner).select { |owner| owner.respond_to?(:alive?) }
  end

  # Client sessions of this database, other than this thread's, that are
  # running a statement or holding a transaction open.
  def other_sessions(pool)
    pool.with_connection do |conn|
      conn.select_all(<<~SQL).to_a
        SELECT pid, state, backend_type, xact_start, wait_event_type, wait_event, LEFT(query, #{QUERY_CHARS}) AS query
        FROM pg_stat_activity
        WHERE datname = current_database() AND pid <> pg_backend_pid()
          AND state IN ('active', 'idle in transaction', 'idle in transaction (aborted)')
          AND backend_type = 'client backend' -- not autovacuum or other PostgreSQL background workers
        ORDER BY pid
      SQL
    end
  end

  def leak_report(pool, leaked, example)
    "#{leaked.size} connection(s) still leased by exited thread(s) — leaked by a worker " \
      "(returned to the pool after this report)#{context(example)}\n" \
      "  pool: #{pool_stat(pool)}\n" \
      "#{leaked.map { |owner| "  leaked: #{owner_details(owner)}" }.join("\n")}"
  end

  def blocking_report(pool, busy, sessions, wait, example)
    parts = []
    parts << "#{busy.size} connection(s) still leased by other live thread(s)" if busy.any?
    parts << "#{sessions.size} other database session(s) still active or in a transaction" if sessions.any?
    lines = [ "#{parts.join('; ')} after waiting #{wait}s#{context(example)}", "  pool: #{pool_stat(pool)}" ]
    lines.concat(busy.map { |owner| "  pool connection leased by #{owner_details(owner)}" })
    lines.concat(sessions.map { |row| "  postgres backend #{session_details(row)}" })
    lines.join("\n")
  end

  def context(example)
    example ? " (#{example.id})" : ""
  end

  def pool_stat(pool)
    pool.stat.slice(:size, :connections, :busy, :dead, :idle, :waiting).map { |key, value| "#{key}=#{value}" }.join(" ")
  end

  def owner_details(thread)
    details = "thread #{thread.inspect} name=#{thread.name.inspect} alive=#{thread.alive?} status=#{thread.status.inspect}"
    trace = thread.alive? ? Array(thread.backtrace).first(BACKTRACE_LINES) : []
    trace.any? ? "#{details}\n#{trace.map { |line| "      #{line}" }.join("\n")}" : details
  end

  def session_details(row)
    "pid=#{row['pid']} state=#{row['state'].inspect} xact_start=#{row['xact_start'].inspect} " \
      "wait_event_type=#{row['wait_event_type'].inspect} wait_event=#{row['wait_event'].inspect} query=#{row['query'].inspect}"
  end

  def monotonic_now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
end
