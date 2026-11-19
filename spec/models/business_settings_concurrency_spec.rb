require "rails_helper"

# Business#settings under real concurrency — TWO database connections: an
# admin settings save (from a copy read earlier) and the audited warehouse
# access mode switch. Whichever takes the business row lock first, the other
# waits on it (observed in pg_stat_activity) and both changes survive.
#
# Not transactional: refuses to start unless the test database is empty and
# truncates every table afterwards — the harness of
# spec/services/inventory/warehouse_manager_concurrency_spec.rb.
RSpec.describe "Business settings vs warehouse access mode (two connections)" do
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

  def on_other_connection(&block)
    Thread.new { ActiveRecord::Base.connection_pool.with_connection(prevent_permanent_checkout: true, &block) }
          .tap { |t| t.report_on_exception = false }
          .tap { |t| (@threads ||= []) << t }
  end

  def wait_for(queue) = Timeout.timeout(10) { queue.pop }
  def result_of(thread) = thread.join(10)&.value || raise("operation did not finish")

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

  def handshake
    reached = Queue.new
    release = Queue.new
    @releases = (@releases || []) << release
    [ reached, release ]
  end

  let!(:business) { create(:business) }
  let!(:owner)    { create(:user, :owner, business: business) }

  def stored = Business.find(business.id).settings.to_h

  def switch_on
    OrganizationAccess::WarehouseAccessMode.call(business: business.id, actor: User.find(owner.id), fail_closed: true)
  end

  it "a settings save from an earlier copy waits for an in-flight mode switch and keeps it", :aggregate_failures do
    stale = Business.find(business.id) # read before the switch, like a form request in progress
    reached, release = handshake
    allow_any_instance_of(OrganizationAccess::WarehouseAccessMode).to receive(:log_audit!).and_wrap_original do |original, **kwargs|
      reached << true
      release.pop # paused holding the business row lock, settings already updated, not committed
      original.call(**kwargs)
    end

    switch = on_other_connection { switch_on }
    wait_for(reached)
    save = on_other_connection { stale.update!(finance_overdue_days: 21) }
    expect(wait_until_lock_waits("businesses")).to be_present

    release << true
    expect(result_of(switch)).to be_ok
    expect(result_of(save)).to be(true)

    expect(stored).to include("warehouse_access_fail_closed" => true, "finance_overdue_days" => 21)
    expect(AuditLog.where(action: "warehouse_access_mode").count).to eq(1)
  end

  it "a mode switch waits for an in-flight settings save, and both changes survive", :aggregate_failures do
    stale = Business.find(business.id)
    reached, release = handshake
    calls = 0
    allow_any_instance_of(Business).to receive(:merge_settings_onto_stored).and_wrap_original do |original|
      calls += 1
      outcome = original.call # takes the business row lock
      if calls == 1
        reached << true
        release.pop # paused holding the lock, before the UPDATE + COMMIT
      end
      outcome
    end

    save = on_other_connection { stale.update!(finance_notify_thresholds: "5,10") }
    wait_for(reached)
    switch = on_other_connection { switch_on }
    expect(wait_until_lock_waits("businesses")).to be_present

    release << true
    expect(result_of(save)).to be(true)
    expect(result_of(switch)).to be_ok

    expect(stored).to include("warehouse_access_fail_closed" => true, "finance_notify_thresholds" => "5,10")
    expect(AuditLog.where(action: "warehouse_access_mode").count).to eq(1)
  end
end
