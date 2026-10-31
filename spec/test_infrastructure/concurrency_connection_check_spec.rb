require "rails_helper"

# BUG-024 — ConcurrencyConnectionCheck (spec/support), the check the
# two-connection concurrency specs run before truncating: a short pool-reaper
# pass is waited out within the deadline, a connection leased by an exited
# thread is reported as a leak (and handed back), and a live connection or an
# open session that outlasts the deadline blocks truncation with pool and
# PostgreSQL details kept apart.
#
# Not transactional (the other threads and sessions must be real). Writes no
# table rows.
RSpec.describe "ConcurrencyConnectionCheck (BUG-024)" do
  self.use_transactional_tests = false

  let(:pool) { ActiveRecord::Base.connection_pool }

  # The real pool reaper is held off (it maintains a pool only under this
  # lock), so each scenario is exactly the one built here; reaper activity is
  # played explicitly (a thread named like it, pool.reap, pool.keep_alive),
  # none of which takes this lock.
  around { |example| pool.reaper_lock { example.run } }

  def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  def timed
    started = now
    result  = yield
    [ result, now - started ]
  end

  def holder(name: nil, &block)
    Thread.new do
      Thread.current.name = name if name
      pool.with_connection(prevent_permanent_checkout: true, &block)
    end.tap { |t| t.report_on_exception = false }
  end

  # A PostgreSQL session outside the pool, from the test database's own settings.
  def raw_session
    config = ActiveRecord::Base.connection_db_config.configuration_hash
    PG.connect(host: config[:host], port: config[:port], user: config[:username],
               password: config[:password], dbname: config[:database])
  end

  # Like the harnesses: this example's own connection is leased, and the pool
  # and database start without another session in use.
  before do
    ActiveRecord::Base.connection
    expect(ConcurrencyConnectionCheck.call(wait: 0)).to have_attributes(blocking: [], leaks: [])
  end

  after { pool.reap }

  it "passes at once when only this example's connection is in use" do
    result, elapsed = timed { ConcurrencyConnectionCheck.call }

    expect(result.blocking).to be_empty
    expect(result.leaks).to be_empty
    expect(elapsed).to be < 0.5
  end

  it "waits out a short pool-reaper pass instead of failing, within the deadline" do
    leased = Queue.new
    reaper = holder(name: "AR Pool Reaper") do |conn|
      leased << true
      conn.select_value("SELECT 1 FROM pg_sleep(0.3)") # leased and active, as while the reaper resets a connection
    end
    Timeout.timeout(10) { leased.pop }

    result, elapsed = timed { ConcurrencyConnectionCheck.call(wait: 2) }

    expect(result.blocking).to be_empty
    expect(result.leaks).to be_empty
    expect(elapsed).to be >= 0.2
    expect(elapsed).to be < 2
    reaper.join(10)
  end

  it "does not block truncation while the real pool maintenance (keep_alive) runs" do
    2.times.map { holder { |conn| conn.select_value("SELECT 1") } }.each { |t| t.join(10) } # idle connections to ping
    # A few passes, as the reaper makes one per tick (every 20 s by default); a
    # connection kept leased without pause would rightly be reported.
    maintenance = Thread.new { 3.times { pool.keep_alive(0) } }.tap { |t| t.report_on_exception = false }

    result = ConcurrencyConnectionCheck.call(wait: 2)

    maintenance.join(10)
    expect(result.blocking).to be_empty
    expect(result.leaks).to be_empty
  end

  it "does not block truncation while the real pool reaper reclaims leaked connections" do
    2.times.map { Thread.new { pool.with_connection { ActiveRecord::Base.connection.select_value("SELECT 1") } } }
                .each { |t| t.join(10) } # two leases left behind by exited threads
    reaping = Thread.new { pool.reap }

    result = ConcurrencyConnectionCheck.call(wait: 2)

    reaping.join(10)
    expect(result.blocking).to be_empty # the leaks may or may not be seen, depending on who reclaims them first
    expect(pool.stat[:dead]).to eq(0)
  end

  it "reports a connection leased by an exited thread as a leak, hands it back and does not block truncation" do
    leaker_line = __LINE__ + 1
    leaker = Thread.new { pool.with_connection { ActiveRecord::Base.connection.select_value("SELECT 1") } }
    leaker.join(10)
    expect(pool.stat[:dead]).to eq(1)

    result = ConcurrencyConnectionCheck.call(wait: 0.5)

    expect(result.blocking).to be_empty
    expect(result.leaks.size).to eq(1)
    expect(result.leaks.first).to include(
      "1 connection(s) still leased by exited thread(s)",
      "(#{RSpec.current_example.id})",
      "dead=1",
      "alive=false",
      "#{File.basename(__FILE__)}:#{leaker_line}" # Thread#inspect names where the leaking thread was started
    )
    expect(pool.stat[:dead]).to eq(0)
  end

  it "blocks truncation when another live thread still holds a connection past the deadline, naming it" do
    leased  = Queue.new
    release = Queue.new
    worker  = holder(name: "held-worker") do
      leased << true
      release.pop
    end
    Timeout.timeout(10) { leased.pop }

    result, elapsed = timed { ConcurrencyConnectionCheck.call(wait: 0.5) }

    release << true
    worker.join(10)
    expect(elapsed).to be >= 0.5
    expect(elapsed).to be < 1.5
    expect(result.leaks).to be_empty
    expect(result.blocking.size).to eq(1)
    message = result.blocking.first
    expect(message).to include(
      "1 connection(s) still leased by other live thread(s) after waiting 0.5s",
      "(#{RSpec.current_example.id})",
      "busy=2",
      'name="held-worker" alive=true',
      File.basename(__FILE__) # the holder's backtrace
    )
    expect(message).not_to include("postgres backend") # its session is idle, not in a transaction
  end

  it "blocks truncation for a database session inside a transaction, reported apart from the pool" do
    session = raw_session
    session.exec("BEGIN")
    session.exec("SELECT 1")

    result = ConcurrencyConnectionCheck.call(wait: 0.3)

    pid = session.backend_pid
    session.exec("ROLLBACK")
    session.close
    expect(result.leaks).to be_empty
    message = result.blocking.sole
    expect(message).to include("1 other database session(s) still active or in a transaction after waiting 0.3s")
    expect(message).to match(/postgres backend pid=#{pid} state="idle in transaction" xact_start=\S+/)
    expect(message).to include("busy=1")
    expect(message).not_to include("pool connection leased by")
  end

  it "truncates the reported query text of an active session" do
    session = raw_session
    session.send_query("SELECT pg_sleep(0.6) /* #{'x' * 300} */")
    deadline = now + 5
    sleep 0.01 until ConcurrencyConnectionCheck.other_sessions(pool).any? || now > deadline

    result = ConcurrencyConnectionCheck.call(wait: 0.1)

    session.get_last_result
    session.close
    query = result.blocking.sole[/query="([^"]*)"/, 1]
    expect(query).to start_with("SELECT pg_sleep(0.6)")
    expect(query.length).to eq(ConcurrencyConnectionCheck::QUERY_CHARS)
    expect(result.blocking.sole).to include('state="active"', 'wait_event_type="Timeout"')
  end
end
