require "rails_helper"

# "A branch never has an open DR beside a waiting_for_opening one" under real
# concurrency, with TWO database connections. The two states sit in separate
# partial unique indexes, so the DB alone cannot forbid the pair: past-date
# creation (Finance::HistoricalDailyReconciliationCreator) and leaving an
# opening float (Finance::OpeningFloatLeaver) both take
# DailyReconciliation.lock_branch_lifecycle! and re-check under it — the second
# waits, then decides on the first's committed result. (Two OPEN DRs are
# forbidden by idx_dr_one_open_per_branch itself.) A pass is not proof that a
# race is impossible.
#
# Harness (Queue handshake, no sleeps, bounded waits, empty-database guard and
# truncation) copied from
# spec/services/organization_access/branch_lifecycle_concurrency_spec.rb.
RSpec.describe "Branch DR lifecycle — past-date open vs opening-float waiting under concurrency (two connections)" do
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

  # Runs the block on its own thread and database connection (see BUG-024 for
  # prevent_permanent_checkout).
  def on_other_connection(&block)
    Thread.new { ActiveRecord::Base.connection_pool.with_connection(prevent_permanent_checkout: true, &block) }
          .tap { |t| t.report_on_exception = false }
          .tap { |t| (@threads ||= []) << t }
  end

  def wait_for(queue) = Timeout.timeout(10) { queue.pop }
  def result_of(thread) = thread.join(10)&.value || raise("operation did not finish")

  # Bounded wait until another backend is blocked on a lock while running a
  # statement matching `pattern`. Returns the waiting statement.
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

  # Pauses the FIRST audit write of `service_class` (its DR inserted, the
  # transaction still open and the lifecycle lock held) until released.
  def pause_first_audit_of(service_class)
    reached = Queue.new
    release = Queue.new
    calls   = 0
    allow_any_instance_of(service_class).to receive(:log_audit).and_wrap_original do |original, **kwargs|
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

  let(:business) { create(:business) }
  let(:branch)   { create(:branch, business: business) }
  let(:today)    { BusinessDay.current(context: business) }
  let(:past)     { today - 2.days }
  let(:cash_pm)  { PaymentMethod.create!(business: business, name: "Cash", settlement_type: "cash", active: true) }

  let(:actor) do
    role = business.permission_roles.create!(name: "R-#{SecureRandom.hex(3)}",
                                             permissions: %w[create_till_session close_till_session])
    create(:user, business: business).tap { |u| u.update_column(:permission_role_id, role.id) }
  end

  # Today's DR, closed and ready for a float — the only state in which both
  # operations are individually allowed.
  let!(:today_dr) do
    DailyReconciliation.create_for!(branch: branch, business_date: today).tap do |dr|
      dr.update!(state: "closed", closed_at: Time.current)
    end
  end

  def create_past
    Finance::HistoricalDailyReconciliationCreator.new(branch: branch, business_date: past, actor: actor).call
  end

  def leave_float
    Finance::OpeningFloatLeaver.new(actor: actor, daily_reconciliation_id: today_dr.id,
                                    amounts: { cash_pm.id.to_s => { collected_amount: "300", refund_amount: "0" } }).call
  end

  def unfinished_states
    DailyReconciliation.where(branch_id: branch.id, state: %w[open waiting_for_opening]).pluck(:state)
  end

  it "past-date creation first: the float waits on the lifecycle lock, then is refused" do
    actor && cash_pm
    reached, release = pause_first_audit_of(Finance::HistoricalDailyReconciliationCreator)
    creation = on_other_connection { create_past }
    wait_for(reached) # past DR inserted open, lock held — not committed

    float = on_other_connection { leave_float }
    expect(wait_until_lock_waits("%pg_advisory_xact_lock%")).to match(/pg_advisory_xact_lock/)
    expect(float.join(0)).to be_nil

    release << true
    expect(result_of(creation)).to be_ok
    expect(result_of(float).error).to eq(I18n.t("opening_floats.errors.another_day_open",
                                                date: I18n.l(past, format: :long)))

    expect(unfinished_states).to eq(%w[open])
    expect(TillHandover.where(opening_float_declaration: true)).to be_empty
  end

  it "opening float first: the past-date creation waits on the lifecycle lock, then is refused" do
    actor && cash_pm
    reached, release = pause_first_audit_of(Finance::NextDayDrPreparer)
    float = on_other_connection { leave_float }
    wait_for(reached) # waiting DR inserted, lock held — not committed

    creation = on_other_connection { create_past }
    expect(wait_until_lock_waits("%pg_advisory_xact_lock%")).to match(/pg_advisory_xact_lock/)
    expect(creation.join(0)).to be_nil

    release << true
    expect(result_of(float)).to be_ok
    expect(result_of(creation).error).to eq(I18n.t("finance.daily_reconciliations.errors.another_day_open_or_waiting"))

    expect(unfinished_states).to eq(%w[waiting_for_opening])
    expect(DailyReconciliation.where(branch_id: branch.id, business_date: past)).to be_empty
    expect(AuditLog.where(action: "create_historical")).to be_empty
  end
end
