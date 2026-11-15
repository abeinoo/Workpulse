require "rails_helper"

# Two concurrent registrations of the same pending account, proven with TWO
# database connections (a second connection is the only thing a row lock can
# block). The first registration is paused (blocking Queue handshake, no sleeps)
# inside its row lock, after setting the password and while writing its audit
# entry; the second is then started and observed waiting on the users row
# (pg_stat_activity). Safe outcome: exactly one registration succeeds, the
# second is refused with the generic message after re-checking committed state,
# the first password is kept, and one audit entry exists.
#
# Not transactional (the other connection must see committed rows): every
# example refuses to start unless the test database is empty and truncates every
# table afterwards — the harness of spec/services/inventory/document_voider_concurrency_spec.rb.
RSpec.describe "Users::RegistrationService concurrency (two connections)" do
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

  # Pauses the first audit insert — inside the first registration's row lock,
  # after its password was saved — until released.
  def pause_first_audit_write
    reached = Queue.new
    release = Queue.new
    calls   = 0
    allow(AuditLog).to receive(:create!).and_wrap_original do |original, *args, **kwargs, &blk|
      calls += 1
      if calls == 1
        reached << true
        release.pop
      end
      original.call(*args, **kwargs, &blk)
    end
    @releases = (@releases || []) << release
    [ reached, release ]
  end

  def register(phone, password)
    Users::RegistrationService.call(phone_number: phone, password: password, password_confirmation: password)
  end

  let!(:pending) { create(:user, :phone_only, :unregistered, phone_number: "01012345678") }

  it "lets exactly one of two overlapping registrations succeed; the second waits on the row, then is refused" do
    reached, release = pause_first_audit_write

    first = on_other_connection { register("01012345678", "first-pass1") }
    wait_for(reached) # row locked, password saved — not committed

    second = on_other_connection { register("+201012345678", "second-pass2") }
    expect(wait_until_lock_waits("users")).to match(/FOR UPDATE/i)
    expect(second.join(0)).to be_nil

    release << true
    expect(result_of(first)).to be_success
    refused = result_of(second)
    expect([ refused.success?, refused.error ]).to eq([ false, I18n.t("auth.register.not_available") ])

    stored = User.find(pending.id)
    expect(stored.valid_password?("first-pass1")).to be(true)
    expect(stored.valid_password?("second-pass2")).to be(false)
    expect(AuditLog.where(action: "account_registered").count).to eq(1)
    expect(User.count).to eq(1)
  end

  it "never activates the account twice when both registrations start together" do
    start   = Queue.new
    threads = [ "pass-one-1", "pass-two-2" ].map do |password|
      on_other_connection do
        start.pop
        register("01012345678", password)
      end
    end
    2.times { start << true }

    results = threads.map { |thread| result_of(thread) }
    expect(results.count(&:success?)).to eq(1)
    expect(AuditLog.where(action: "account_registered").count).to eq(1)
    winner = results.find(&:success?)
    expect(User.find(pending.id).encrypted_password).to eq(winner.user.encrypted_password)
  end
end
