require "rails_helper"

# Phase 1 unit 6 under real concurrency — TWO database connections: a
# deactivation and an incoming movement of the same product/warehouse pair
# serialize on the availability row (deactivation FOR UPDATE, the posting
# FOR SHARE), so stock never lands in a pair that was deactivated meanwhile.
#
# Not transactional: refuses to start unless the test database is empty and
# truncates every table afterwards (harness of
# spec/services/inventory/product_availability_concurrency_spec.rb).
RSpec.describe "Incoming stock vs deactivation (two connections)" do
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
  let!(:receiver) { user_with_stock_permissions(business, :view_inventory, :confirm_goods_receipts, name: "Receiver") }
  let!(:main)     { business.warehouses.create!(name: "Main Warehouse", kind: "central") }
  let!(:nasr_wh)  { business.warehouses.create!(name: "Nasr City WH", kind: "central") }
  let!(:shampoo)  { business.products.create!(name: "Shampoo", sku: "SH-1", initial_cost_price: 5, average_cost_price: 5) }

  def manager = Inventory::ProductAvailabilityManager.new(actor: User.find(owner.id))

  let!(:setting) do
    added = manager.add_many(warehouse_id: nasr_wh.id, items: [ { product_id: shampoo.id } ])
    raise "seed add failed: #{added.error}" unless added.ok?
    ProductWarehouseSetting.find_by!(product: shampoo, warehouse: nasr_wh)
  end

  before do
    r = business.goods_receipts.build(warehouse: main, received_on: Date.current)
    r.items.build(product: shampoo, quantity: 10, unit_cost: 5)
    raise "seed receipt failed" unless Inventory::GoodsReceiptPoster.new(r).call.ok?
  end

  def transfer_into_nasr
    t = business.stock_transfers.build(source_warehouse: Warehouse.find(main.id), destination_warehouse: Warehouse.find(nasr_wh.id),
                                       transferred_on: Date.current)
    t.items.build(product: Product.find(shampoo.id), quantity: 2)
    Inventory::StockTransferPoster.new(t).call
  end

  def nasr_stock = Product.find(shampoo.id).stock_in(Warehouse.find(nasr_wh.id))

  def pause_deactivation_audit
    reached, release = handshake
    allow_any_instance_of(Inventory::ProductAvailabilityManager).to receive(:log_audit!).and_wrap_original do |original, **kwargs|
      if kwargs[:action] == "availability_deactivate"
        reached << true
        release.pop
      end
      original.call(**kwargs)
    end
    [ reached, release ]
  end

  it "17. a transfer started while a deactivation is in flight waits, then is refused", :aggregate_failures do
    reached, release = pause_deactivation_audit
    deactivation = on_other_connection { manager.deactivate(setting_id: setting.id, reason: "closing this line") }
    wait_for(reached)

    incoming = on_other_connection { transfer_into_nasr }
    expect(wait_until_lock_waits("product_warehouse_settings")).to be_present

    release << true
    expect(result_of(deactivation)).to be_ok
    result = result_of(incoming)
    expect(result).not_to be_ok
    expect(result.transfer.errors.full_messages.join).to include("inactive")
    expect(StockTransfer.count).to eq(0)
    expect(nasr_stock).to eq(0)
  end

  it "17. a goods receipt confirmed while a deactivation is in flight waits, then is refused", :aggregate_failures do
    receipt = business.goods_receipts.build(warehouse: nasr_wh, received_on: Date.current)
    receipt.items.build(product: shampoo, quantity: 3, unit_cost: 5)
    receipt.save!
    receipt.update_column(:approval_status, "approved")

    reached, release = pause_deactivation_audit
    deactivation = on_other_connection { manager.deactivate(setting_id: setting.id, reason: "closing this line") }
    wait_for(reached)

    confirmation = on_other_connection do
      Inventory::GoodsReceiptConfirmationService.new(goods_receipt_id: receipt.id, actor: User.find(receiver.id)).call
    end
    expect(wait_until_lock_waits("product_warehouse_settings")).to be_present

    release << true
    expect(result_of(deactivation)).to be_ok
    expect(result_of(confirmation)).not_to be_ok
    expect(GoodsReceipt.find(receipt.id)).to be_draft
    expect(nasr_stock).to eq(0)
  end

  it "17. a deactivation started while a transfer is posting waits for it and reports the arrived stock", :aggregate_failures do
    reached, release = handshake
    allow_any_instance_of(Inventory::StockTransferPoster).to receive(:post_item).and_wrap_original do |original, *args|
      reached << true
      release.pop
      original.call(*args)
    end

    incoming = on_other_connection { transfer_into_nasr }
    wait_for(reached) # past the availability check, holding the row FOR SHARE

    deactivation = on_other_connection { manager.deactivate(setting_id: setting.id, reason: "closing this line") }
    expect(wait_until_lock_waits("product_warehouse_settings")).to be_present

    release << true
    expect(result_of(incoming)).to be_ok
    result = result_of(deactivation)
    expect(result).to be_ok
    expect(result.dependencies[:on_hand]).to eq("2.0")
    expect(nasr_stock).to eq(2)
    expect(ProductWarehouseSetting.find(setting.id)).to be_status_inactive
  end
end
