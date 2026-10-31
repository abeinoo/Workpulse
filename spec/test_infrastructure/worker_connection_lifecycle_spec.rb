require "rails_helper"

# BUG-024 — the contract every two-connection spec relies on: a worker thread
# started as `Thread.new { pool.with_connection(prevent_permanent_checkout: true) { … } }`
# returns its connection to the pool when it finishes, even when code inside
# calls `ActiveRecord::Base.connection` / `Model.connection` (as
# User#assign_employee_code and the number sequencers do), and even when it
# raises. Without the flag (Rails 8.1), such a call makes the lease permanent
# and the connection stays leased by the dead thread.
#
# Not transactional (a transactional example pins one connection that every
# thread would share). Writes no table rows: SELECTs and an advisory lock only.
RSpec.describe "Worker thread connection lifecycle (BUG-024)" do
  self.use_transactional_tests = false

  let(:pool) { ActiveRecord::Base.connection_pool }

  def worker(prevent_permanent_checkout: true, &block)
    Thread.new { pool.with_connection(prevent_permanent_checkout: prevent_permanent_checkout, &block) }
          .tap { |t| t.report_on_exception = false }
  end

  def dead_connections = pool.connections.select { |c| c.in_use? && !c.owner.alive? }
  def busy_elsewhere   = pool.connections.select { |c| c.in_use? && c.owner.alive? && !c.owner.equal?(Thread.current) }

  # Leases this example's own connection (like the harnesses' before hook) and
  # requires a pool without leaked connections, so each example starts clean.
  before do
    @main_connection = ActiveRecord::Base.connection
    expect(dead_connections).to be_empty
  end

  # The one example that leaks on purpose reclaims through Rails' own API
  # (reap steals only dead-owned connections, resets and checks them in).
  after { pool.reap }

  it "returns the connection after a worker calls ActiveRecord::Base.connection; that call yields the block's connection" do
    block_connection = nil
    inner_connection = nil
    worker do |conn|
      block_connection = conn
      inner_connection = ActiveRecord::Base.connection
      inner_connection.select_value("SELECT 1")
    end.join(10)

    expect(inner_connection).to equal(block_connection)
    expect(block_connection.owner).to be_nil
    expect(dead_connections).to be_empty
    expect(busy_elsewhere).to be_empty
  end

  it "without the flag the same worker leaves its connection leased by the dead thread (what BUG-024 leaked)" do
    thread = worker(prevent_permanent_checkout: false) { ActiveRecord::Base.connection.select_value("SELECT 1") }
    thread.join(10)

    expect(thread.alive?).to be(false)
    expect(dead_connections.map(&:owner)).to eq([ thread ])
  end

  it "returns the connection of a worker that raises, and the exception reaches the joining thread" do
    block_connection = nil
    thread = worker do |conn|
      block_connection = conn
      ActiveRecord::Base.connection.select_value("SELECT 1")
      raise ArgumentError, "worker failed"
    end

    expect { thread.join(10) }.to raise_error(ArgumentError, "worker failed")
    expect { thread.value }.to raise_error(ArgumentError, "worker failed")
    expect(block_connection.owner).to be_nil
    expect(dead_connections).to be_empty
  end

  it "keeps ownership with the worker while it runs and leaves this thread's connection alone" do
    running  = Queue.new
    finish   = Queue.new
    owner_seen = nil
    thread = worker do |conn|
      owner_seen = conn.owner
      running << conn
      finish.pop
    end
    worker_connection = Timeout.timeout(10) { running.pop }

    expect(owner_seen).to equal(thread)
    expect(worker_connection).not_to equal(@main_connection)
    expect(busy_elsewhere).to eq([ worker_connection ])

    finish << true
    thread.join(10)

    expect(worker_connection.owner).to be_nil
    expect(ActiveRecord::Base.connection).to equal(@main_connection)
    expect(@main_connection.owner).to equal(Thread.current)
  end

  it "survives an explicit lease_connection and a nested with_connection inside the worker without a double check-in" do
    errors = []
    thread = worker do |conn|
      ActiveRecord::Base.lease_connection.select_value("SELECT 1") # sets the lease sticky
      pool.with_connection { |nested| errors << :not_same unless nested.equal?(conn) }
    rescue ActiveRecord::ActiveRecordError => e
      errors << e
      raise
    end

    expect { thread.join(10) }.not_to raise_error
    expect(errors).to be_empty
    expect(dead_connections).to be_empty
    expect(busy_elsewhere).to be_empty
  end

  it "keeps a transaction-scoped advisory lock taken through ActiveRecord::Base.connection on the worker's session until commit" do
    key      = [ 924_024, 1 ]
    locked   = Queue.new
    commit   = Queue.new
    held_pid = nil
    thread = worker do |conn|
      ActiveRecord::Base.transaction do
        ActiveRecord::Base.connection.execute("SELECT pg_advisory_xact_lock(#{key.join(', ')})")
        held_pid = conn.select_value("SELECT pg_backend_pid()")
        locked << true
        commit.pop
      end
    end
    Timeout.timeout(10) { locked.pop }

    lock_holders = lambda do
      @main_connection.select_values(<<~SQL)
        SELECT pid FROM pg_locks
        WHERE locktype = 'advisory' AND classid = #{key[0]} AND objid = #{key[1]} AND objsubid = 2 AND granted
      SQL
    end
    expect(lock_holders.call).to eq([ held_pid ])
    expect(@main_connection.select_value("SELECT pg_try_advisory_xact_lock(#{key.join(', ')})")).to be(false)

    commit << true
    thread.join(10)

    expect(lock_holders.call).to be_empty
    expect(dead_connections).to be_empty
  end
end
