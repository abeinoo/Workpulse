require "rails_helper"

# Inventory::ProductAvailabilityManager under real concurrency — TWO database
# connections. The first operation is paused inside its transaction (holding
# its lock); the competing one is observed waiting (pg_stat_activity).
#
# Not transactional: refuses to start unless the test database is empty and
# truncates every table afterwards — the harness of
# spec/services/inventory/warehouse_manager_concurrency_spec.rb.
RSpec.describe "Product availability concurrency (two connections)" do
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
  let!(:owner2)   { user_with_stock_permissions(business, :view_inventory, :manage_product_availability, name: "Availability 2") }
  let!(:central)  { business.warehouses.create!(name: "Main Warehouse", kind: "central") }
  let!(:shampoo)  { business.products.create!(name: "Shampoo", sku: "SH-1", initial_cost_price: 5, average_cost_price: 5) }

  def manager(actor) = Inventory::ProductAvailabilityManager.new(actor: User.find(actor.id))

  def pause_first_audit(action)
    reached, release = handshake
    calls = 0
    allow_any_instance_of(Inventory::ProductAvailabilityManager).to receive(:log_audit!).and_wrap_original do |original, **kwargs|
      if kwargs[:action] == action && (calls += 1) == 1
        reached << true
        release.pop
      end
      original.call(**kwargs)
    end
    [ reached, release ]
  end

  it "two simultaneous adds of the same product to one warehouse create exactly one pair", :aggregate_failures do
    reached, release = pause_first_audit("availability_add")
    item = [ { product_id: shampoo.id, low_stock_level: 3, reorder_quantity: 10 } ]

    first = on_other_connection { manager(owner).add_many(warehouse_id: central.id, items: item) }
    wait_for(reached)
    second = on_other_connection { manager(owner2).add_many(warehouse_id: central.id, items: item) }
    expect(wait_until_lock_waits("warehouses")).to be_present # serialized on the warehouse row

    release << true
    results = [ result_of(first), result_of(second) ]
    expect(results.map(&:ok?)).to eq([ true, true ])
    expect(results.map { |r| r.records.size }).to eq([ 1, 0 ])
    expect(results.last.skipped.map(&:product_id)).to eq([ shampoo.id ])
    expect(ProductWarehouseSetting.where(product: shampoo, warehouse: central).count).to eq(1)
    expect(AuditLog.where(action: "availability_add").count).to eq(1)
  end

  it "the product page's first save of an Included branch and the warehouse tab's add serialize on the warehouse row (one pair)", :aggregate_failures do
    branch_wh = business.warehouses.create!(name: "Nasr City WH", kind: "branch", branch: create(:branch, business: business))
    reached, release = pause_first_audit("availability_add")

    from_product = on_other_connection do
      manager(owner).save_settings(product_id: shampoo.id, warehouse_id: branch_wh.id, low_stock_level: 4, reorder_quantity: 8)
    end
    wait_for(reached)
    from_tab = on_other_connection { manager(owner2).add_many(warehouse_id: branch_wh.id, items: [ { product_id: shampoo.id } ]) }
    expect(wait_until_lock_waits("warehouses")).to be_present

    release << true
    first, second = result_of(from_product), result_of(from_tab)
    expect([ first.ok?, second.ok? ]).to eq([ true, true ])
    expect(second.records).to be_empty
    expect(second.skipped.map(&:warehouse_id)).to eq([ branch_wh.id ])
    expect(ProductWarehouseSetting.where(product: shampoo).sole).to have_attributes(low_stock_level: 4, reorder_quantity: 8)
    expect(AuditLog.where(action: "availability_add").count).to eq(1)
  end

  it "an exclusion and a first settings save of the same Included branch never create two rows", :aggregate_failures do
    branch_wh = business.warehouses.create!(name: "Shubra WH", kind: "branch", branch: create(:branch, business: business))
    reached, release = pause_first_audit("availability_deactivate")

    exclusion = on_other_connection { manager(owner).exclude(product_id: shampoo.id, warehouse_id: branch_wh.id, reason: "not sold") }
    wait_for(reached)
    save = on_other_connection do
      manager(owner2).save_settings(product_id: shampoo.id, warehouse_id: branch_wh.id, low_stock_level: 3, reorder_quantity: 0)
    end
    expect(wait_until_lock_waits("warehouses")).to be_present

    release << true
    expect(result_of(exclusion)).to be_ok
    expect(result_of(save).error).to eq(:inactive)
    expect(ProductWarehouseSetting.where(product: shampoo).sole).to have_attributes(status: "inactive", low_stock_level: 0)
  end

  it "a settings update waits for an in-flight deactivation and is then refused (no lost transition)", :aggregate_failures do
    manager(owner).add_many(warehouse_id: central.id, items: [ { product_id: shampoo.id, low_stock_level: 3, reorder_quantity: 10 } ])
    row_id = ProductWarehouseSetting.find_by!(product: shampoo).id
    reached, release = pause_first_audit("availability_deactivate")

    deactivation = on_other_connection { manager(owner).deactivate(setting_id: row_id, reason: "not used") }
    wait_for(reached)
    update = on_other_connection do
      manager(owner2).update(setting_id: row_id, low_stock_level: 9, reorder_quantity: 9, receive_low_stock_notification: true)
    end
    expect(wait_until_lock_waits("product_warehouse_settings")).to be_present

    release << true
    expect(result_of(deactivation)).to be_ok
    expect(result_of(update).error).to eq(:inactive)

    row = ProductWarehouseSetting.find(row_id)
    expect(row).to be_status_inactive
    expect([ row.low_stock_level, row.reorder_quantity ]).to eq([ 3, 10 ])
    expect(AuditLog.where(action: "availability_update")).to be_empty
  end
end
