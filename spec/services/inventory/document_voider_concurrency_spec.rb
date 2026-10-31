require "rails_helper"

# BUG-017 (docs/quality/deferred-bugs.md) — two voids of the same posted stock
# issue, stock transfer or stock adjustment, proven with TWO database connections
# (a second connection is the only thing a row lock can block). Each void runs as
# the controllers run it: a fresh policy-scoped copy, then Inventory::DocumentVoider.
# The first void is paused (blocking Queue handshake, no sleeps) inside its
# transaction, after its reversal movements and void update — on its first
# ProductCostRecalculator#recompute! — and the second void is then started and
# observed waiting on the document row (pg_stat_activity). Each example asserts the
# SAFE outcome: the second void is refused as already voided and writes nothing —
# one set of reversal movements, the stock restored once, the first voider kept.
#
# Not transactional (the other connection must see committed rows): every
# example refuses to start unless the test database is empty and truncates every
# table afterwards — the harness of spec/services/requests/advance_payment_concurrency_spec.rb.
RSpec.describe "Inventory::DocumentVoider concurrency (two connections, BUG-017)" do
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
  # prevent_permanent_checkout: a `Model.connection` call inside the block (e.g.
  # User#assign_employee_code) would otherwise pin the connection to this thread
  # past the block, leaving it leased by a dead thread (BUG-024).
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

  # Pauses the first cost recompute — inside DocumentVoider's transaction, after
  # its reversal movements and void update — until released.
  def pause_first_void
    reached = Queue.new
    release = Queue.new
    calls   = 0
    allow_any_instance_of(Inventory::ProductCostRecalculator).to receive(:recompute!).and_wrap_original do |original, *args|
      calls += 1
      if calls == 1
        reached << true
        release.pop
      end
      original.call(*args)
    end
    @releases = (@releases || []) << release
    [ reached, release ]
  end

  let(:business)    { create(:business) }
  let(:first_user)  { create(:user, :super_admin, business: business) }
  let(:second_user) { create(:user, :super_admin, business: business) }
  let(:main)        { business.warehouses.create!(name: "Main") }
  let(:branch)      { business.warehouses.create!(name: "Branch") }
  let(:product) do
    business.products.create!(name: "Hair Color", sku: "HC-1", initial_cost_price: 0, average_cost_price: 0)
  end

  def stock!(qty)
    r = business.goods_receipts.build(warehouse: main, received_on: Date.current)
    r.items.build(product: product, quantity: qty, unit_cost: 100)
    Inventory::GoodsReceiptPoster.new(r).call.receipt
  end

  # As the controllers do: a fresh, unlocked copy per request.
  def void(klass, id, user) = Inventory::DocumentVoider.new(klass.find(id), user: user, reason: "duplicate").call

  def reversals(doc) = InventoryMovement.where(source_type: doc.class.name, source_id: doc.id, reason: "reversal")

  def race_two_voids(doc)
    reached, release = pause_first_void
    first = on_other_connection { void(doc.class, doc.id, first_user) }
    wait_for(reached) # reversal written and document marked voided — not committed

    second = on_other_connection { void(doc.class, doc.id, second_user) }
    expect(wait_until_lock_waits(doc.class.table_name)).to be_present
    expect(second.join(0)).to be_nil

    release << true
    [ result_of(first), result_of(second) ]
  end

  def expect_second_refused(doc, first, second)
    expect(first).to be_ok
    expect(second).not_to be_ok
    expect(second.document.errors.details).to eq(base: [ { error: :already_voided } ])
    final = doc.class.find(doc.id)
    expect([ final.voided_by_id, final.void_reason ]).to eq([ first_user.id, "duplicate" ])
  end

  it "stock issue: one reversal — the second void is refused; the issued quantity returns once", :aggregate_failures do
    stock!(10)
    branch_record = business.branches.first_or_create!(name: "Void Branch", active: true)
    issue = business.stock_issues.build(warehouse: main, branch: branch_record, issued_on: Date.current)
    issue.items.build(product: product, quantity: 4)
    issue = approve_and_post_stock_issue(issue).issue
    expect(product.reload.current_stock).to eq(6)

    first, second = race_two_voids(issue)

    expect_second_refused(issue, first, second)
    expect(reversals(issue).count).to eq(1)
    expect(product.reload.current_stock).to eq(10)
  end

  it "stock transfer: one reversal pair — the second void is refused; nothing goes negative", :aggregate_failures do
    stock!(10)
    transfer = business.stock_transfers.build(source_warehouse: main, destination_warehouse: branch, transferred_on: Date.current)
    transfer.items.build(product: product, quantity: 6)
    Inventory::StockTransferPoster.new(transfer).call
    expect([ product.stock_in(main), product.stock_in(branch) ]).to eq([ 4, 6 ])

    first, second = race_two_voids(transfer)

    expect_second_refused(transfer, first, second)
    expect(reversals(transfer).count).to eq(2) # one out of Branch, one into Main
    expect([ product.reload.stock_in(main), product.stock_in(branch) ]).to eq([ 10, 0 ])
  end

  it "stock adjustment: one reversal — the second void is refused; the adjusted quantity returns once", :aggregate_failures do
    stock!(10)
    adjustment = business.stock_adjustments.build(warehouse: main, adjusted_on: Date.current, reason: "damaged")
    adjustment.items.build(product: product, quantity_difference: -3)
    Inventory::AdjustmentPoster.new(adjustment).call
    expect(product.reload.current_stock).to eq(7)

    first, second = race_two_voids(adjustment)

    expect_second_refused(adjustment, first, second)
    expect(reversals(adjustment).count).to eq(1)
    expect(product.reload.current_stock).to eq(10)
  end
end
