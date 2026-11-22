require "rails_helper"

# Concurrency of multi-unit postings with TWO database connections
# (docs/inventory/multi_unit_nested_packaging_design.md §10.5 – 10.6; BUG-071). The first
# operation is paused inside its transaction, after its product lock and first
# movement, at its first packaging step; the second is then started and must
# wait on the product row lock. Each example asserts the safe outcome.
#
# Not transactional (the other connection must see committed rows): the
# harness of goods_receipt_void_concurrency_spec.rb (empty database required,
# every table truncated afterwards).
RSpec.describe "Multi-unit posting concurrency (two connections)" do
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

  # Pauses the first packaging step (after the product lock and the first
  # movement) until released; later calls run through.
  def pause_first_packaging_step
    reached = Queue.new
    release = Queue.new
    calls   = 0
    allow_any_instance_of(Inventory::Packaging::Session).to receive(:apply!).and_wrap_original do |original, *args, **kwargs, &block|
      calls += 1
      if calls == 1
        reached << true
        release.pop
      end
      original.call(*args, **kwargs, &block)
    end
    @releases = (@releases || []) << release
    [ reached, release ]
  end

  let(:business) { create(:business) }
  let(:owner)    { create(:user, :owner, business: business) }
  let(:main)     { business.warehouses.create!(name: "Main") }
  let(:annex)    { business.warehouses.create!(name: "Annex") }
  let(:razor) do
    product = business.products.create!(name: "Razor", sku: "RZ-1", initial_cost_price: 0, average_cost_price: 0)
    configure_packaging!(product, owner, [ "box", 10 ], [ "carton", 12 ])
  end

  def receipt_of(product, cost)
    receipt = business.goods_receipts.build(warehouse: main, received_on: Date.current)
    receipt.items.build(product: product, entered_quantity: 1, packaging_level: level_of(product, "carton"), entered_unit_cost: cost)
    receipt
  end

  def transfer_of(product, boxes)
    transfer = business.stock_transfers.build(source_warehouse: main, destination_warehouse: annex, transferred_on: Date.current)
    transfer.items.build(product: product, entered_quantity: boxes, packaging_level: level_of(product, "box"))
    transfer
  end

  it "BUG-071: two receipts of one product posted together both blend into the average", :aggregate_failures do
    razor
    reached, release = pause_first_packaging_step
    first = on_other_connection { Inventory::GoodsReceiptPoster.new(receipt_of(razor, 120)).call }
    wait_for(reached)
    second = on_other_connection { Inventory::GoodsReceiptPoster.new(receipt_of(razor, 240)).call }
    expect(wait_until_lock_waits("%")).to be_present

    release << true
    expect([ result_of(first).ok?, result_of(second).ok? ]).to eq([ true, true ])
    expect(Product.find(razor.id).average_cost_price).to eq(BigDecimal("1.5")) # (120 × 1 + 120 × 2) / 240
    expect(InventoryAverageCostChange.where(product_id: razor.id).count).to eq(2)
  end

  it "two transfers opening the same carton: the second sees the first's packaging and is refused, nothing goes negative", :aggregate_failures do
    Inventory::GoodsReceiptPoster.new(receipt_of(razor, 120)).call      # 1 carton = 12 boxes
    reached, release = pause_first_packaging_step
    first = on_other_connection { Inventory::StockTransferPoster.new(transfer_of(razor, 7)).call }
    wait_for(reached)
    second = on_other_connection { Inventory::StockTransferPoster.new(transfer_of(razor, 7)).call }
    expect(wait_until_lock_waits("%")).to be_present

    release << true
    expect([ result_of(first).ok?, result_of(second).ok? ]).to eq([ true, false ])
    expect(packaging_state(Product.find(razor.id), main)).to eq("carton" => 0, "box" => 5, loose: 0, total: 50)
    expect(packaging_state(Product.find(razor.id), annex)).to eq("carton" => 0, "box" => 7, loose: 0, total: 70)
  end
end
