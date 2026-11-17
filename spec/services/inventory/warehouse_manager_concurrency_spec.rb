require "rails_helper"

# Inventory::WarehouseManager under real concurrency — TWO database connections.
# The first operation is paused (blocking Queue handshake, no sleeps) inside its
# transaction; the competing one is started and observed waiting on a lock
# (pg_stat_activity). Each example asserts the SAFE outcome.
#
# Not transactional: refuses to start unless the test database is empty and
# truncates every table afterwards — the harness of
# spec/services/inventory/stock_count_concurrency_spec.rb.
RSpec.describe "Warehouse manager concurrency (two connections)" do
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

  # A paused handshake: [reached, release]. Pushes to reached, waits on release.
  def handshake
    reached = Queue.new
    release = Queue.new
    @releases = (@releases || []) << release
    [ reached, release ]
  end

  # Created eagerly on the main connection: nothing is built lazily inside a
  # worker thread (its own transaction must contain only the operation under test).
  let!(:business)     { create(:business) }
  # access_all_warehouses: creating a warehouse requires it on top of manage_inventory (PR 5, D4).
  let!(:actor)        { user_with_stock_permissions(business, :view_inventory, :manage_inventory, :access_all_warehouses, name: "Manager") }
  let!(:actor2)       { user_with_stock_permissions(business, :view_inventory, :manage_inventory, :access_all_warehouses, name: "Manager 2") }
  let!(:sales_branch) { create(:branch, business: business, branch_type: "sales") }
  let!(:product)      { business.products.create!(name: "Shampoo", sku: "SH-1", average_cost_price: 5) }

  def movement!(warehouse)
    InventoryMovement.create!(business: business, product: product, warehouse: warehouse, direction: :in,
                              reason: :opening_balance, quantity: 3, unit_cost: 5, occurred_on: Date.new(2026, 1, 1))
  end

  it "two simultaneous branch-warehouse creations for one branch create exactly one", :aggregate_failures do
    branch_id = sales_branch.id
    reached, release = handshake
    calls = 0
    # Pause the first creation after its INSERT, before its audit + COMMIT.
    allow_any_instance_of(Inventory::WarehouseManager).to receive(:log_audit!).and_wrap_original do |original, **kwargs|
      calls += 1
      if calls == 1
        reached << true
        release.pop
      end
      original.call(**kwargs)
    end

    first = on_other_connection { Inventory::WarehouseManager.new(actor: actor).create(kind: "branch", name: "A", branch_id: branch_id) }
    wait_for(reached)
    second = on_other_connection { Inventory::WarehouseManager.new(actor: actor2).create(kind: "branch", name: "B", branch_id: branch_id) }
    # The second creation waits at the business row the first one holds
    # (business -> branch lock order); once the first commits, it sees that
    # branch warehouse. The unique index stays the final guard (warehouse_manager_spec).
    expect(wait_until_lock_waits("businesses")).to be_present

    release << true
    results = [ result_of(first), result_of(second) ]
    expect(results.map(&:ok?)).to eq([ true, false ])
    expect(results.last.code).to eq(:branch_already_has_warehouse)
    expect(Warehouse.where(branch_id: branch_id).pluck(:name)).to eq([ "A" ])
    expect(AuditLog.where(auditable_type: "Warehouse", action: "create").count).to eq(1)
  end

  it "a deletion waits for in-flight inventory activity and then refuses", :aggregate_failures do
    warehouse = Inventory::WarehouseManager.new(actor: actor).create(kind: "central", name: "Spare").warehouse
    reached, release = handshake

    activity = on_other_connection do
      InventoryMovement.transaction do
        movement!(warehouse) # holds a key-share lock on the warehouse row
        reached << true
        release.pop
      end
      :committed
    end
    wait_for(reached)
    deletion = on_other_connection { Inventory::WarehouseManager.new(actor: actor2).destroy(warehouse_id: warehouse.id, reason: "spare") }
    expect(wait_until_lock_waits("warehouses")).to be_present
    expect(deletion.join(0)).to be_nil

    release << true
    expect(result_of(activity)).to eq(:committed)
    result = result_of(deletion)
    expect(result.code).to eq(:in_use)
    expect(result.blockers).to include(:inventory_movements, :stock_on_hand)
    expect(Warehouse.exists?(warehouse.id)).to be(true)
    expect(InventoryMovement.where(warehouse_id: warehouse.id).count).to eq(1)
    expect(AuditLog.where(auditable_type: "Warehouse", action: "destroy")).to be_empty
  end

  it "inventory activity racing a committed deletion fails on the foreign key and leaves nothing behind", :aggregate_failures do
    warehouse = Inventory::WarehouseManager.new(actor: actor).create(kind: "central", name: "Spare").warehouse
    warehouse_id = warehouse.id
    reached, release = handshake
    # Pause the deletion after its checks (row locked FOR UPDATE), before the DELETE.
    allow_any_instance_of(Warehouse).to receive(:destroy!).and_wrap_original do |original, *args|
      reached << true
      release.pop
      original.call(*args)
    end

    deletion = on_other_connection { Inventory::WarehouseManager.new(actor: actor).destroy(warehouse_id: warehouse_id, reason: "spare") }
    wait_for(reached)
    activity = on_other_connection do
      movement!(Warehouse.find(warehouse_id))
      :inserted
    rescue ActiveRecord::InvalidForeignKey
      :refused_by_foreign_key
    end
    expect(wait_until_lock_waits("inventory_movements")).to be_present

    release << true
    expect(result_of(deletion)).to be_ok
    expect(result_of(activity)).to eq(:refused_by_foreign_key)
    expect(Warehouse.exists?(warehouse_id)).to be(false)
    expect(InventoryMovement.where(warehouse_id: warehouse_id)).to be_empty
    expect(AuditLog.where(auditable_type: "Warehouse", auditable_id: warehouse_id, action: "destroy").count).to eq(1)
  end
end
