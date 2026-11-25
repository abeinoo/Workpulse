require "rails_helper"

# Stock transfer reservations under real concurrency — TWO database
# connections. The first operation is paused while it holds its locks; the
# second is shown to WAIT on that lock (pg_stat_activity), then the first is
# released and the COMMITTED database state is checked: no stock is reserved
# twice, nothing is posted or released twice, available never goes negative.
#
# Not transactional: refuses to start unless the test database is empty and
# truncates every table afterwards (harness of
# spec/services/inventory/incoming_availability_concurrency_spec.rb).
RSpec.describe "Stock transfer reservations (two connections)" do
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

  # Pauses the FIRST call of `method` on `target` (while the caller holds its
  # locks); every later call runs straight through.
  def pause_first_call(target, method, any_instance: false)
    reached, release = handshake
    calls = Concurrent::AtomicFixnum.new(0)
    wrapper = lambda do |original, *args, **kwargs, &blk|
      if calls.increment == 1
        reached << true
        release.pop
      end
      original.call(*args, **kwargs, &blk)
    end
    stub = any_instance ? allow_any_instance_of(target) : allow(target)
    stub.to receive(method).and_wrap_original(&wrapper)
    [ reached, release ]
  end

  let!(:business)  { create(:business) }
  let!(:source)    { business.warehouses.create!(name: "Main") }
  let!(:dest)      { business.warehouses.create!(name: "Branch") }
  let!(:product)   { business.products.create!(name: "Shampoo", sku: "SH-1", initial_cost_price: 10, average_cost_price: 10) }
  let!(:requester) { user_with_stock_permissions(business, :view_stock_transfers, :create_stock_transfers, name: "Requester") }
  let!(:approver)  do
    user_with_stock_permissions(business, :view_stock_transfers, :approve_stock_transfers, :edit_pending_stock_transfers,
                                :reject_stock_transfers, :cancel_stock_transfers, :dispatch_stock_transfers,
                                :receive_stock_transfers, :resolve_stock_transfer_discrepancies, name: "Approver")
  end
  let!(:issue_approver) { user_with_stock_permissions(business, :view_stock_issues, :approve_stock_issues, name: "Issue approver") }

  before do
    InventoryMovement.create!(business: business, product: product, warehouse: source, direction: :in, reason: :opening_balance,
                              quantity: 100, unit_cost: 10, occurred_on: Date.new(2026, 1, 1))
  end

  def draft(qty)
    Inventory::StockTransferDraftService.new(actor: User.find(requester.id), attributes: {
      source_warehouse_id: source.id, destination_warehouse_id: dest.id,
      items_attributes: { "0" => { product_id: product.id, quantity: qty } }
    }).call.tap { |r| raise r.error unless r.ok? }.transfer
  end

  def submit(transfer) = Inventory::StockTransferSubmission.new(stock_transfer_id: transfer.id, actor: User.find(requester.id)).call
  def approve(transfer) = Inventory::StockTransferApproval.new(stock_transfer_id: transfer.id, actor: User.find(approver.id)).call
  def dispatch(transfer) = Inventory::StockTransferDispatch.new(stock_transfer_id: transfer.id, actor: User.find(approver.id)).call
  def receive_goods(transfer, quantity, close: false)
    item = StockTransfer.find(transfer.id).items.first
    Inventory::StockTransferReceiving.new(stock_transfer_id: transfer.id, actor: User.find(approver.id),
                                          quantities: { item.id => quantity }, close_shortfall: close).call
  end
  def approved(qty) = draft(qty).tap { |t| raise "submit" unless submit(t).ok? }.tap { |t| raise "approve" unless approve(t).ok? }
  def transit_on_hand = Inventory::TransitWarehouse.find_for(Business.find(business.id))&.then { |w| on_hand(w) } || 0

  def reserved
    Inventory::StockAvailability.reserved_by(warehouse_ids: source.id, product_ids: product.id)[[ source.id, product.id ]].to_d
  end

  def on_hand(warehouse = source) = Product.find(product.id).stock_in(Warehouse.find(warehouse.id))

  it "1. two simultaneous submissions cannot reserve the same stock", :aggregate_failures do
    a = draft(60)
    b = draft(60)
    reached, release = pause_first_call(Inventory::StockAvailability, :validate_transfer!)

    first = on_other_connection { submit(a) }
    wait_for(reached) # holds the Product row lock
    second = on_other_connection { submit(b) }
    expect(wait_until_lock_waits("products")).to be_present

    release << true
    expect(result_of(first)).to be_ok
    expect(result_of(second)).not_to be_ok
    expect(StockTransfer.find(a.id)).to be_pending_approval
    expect(StockTransfer.find(b.id)).to be_draft
    expect(reserved).to eq(60)
    expect(on_hand - reserved).to eq(40)
  end

  it "2. a transfer submission and a stock issue approval cannot both take the same stock", :aggregate_failures do
    transfer = draft(70)
    issue = business.stock_issues.build(warehouse: source, issued_on: Date.current)
    issue.items.build(product: product, quantity: 70)
    issue = save_stock_issue_in_status!(issue, :pending_approval)
    reached, release = pause_first_call(Inventory::StockAvailability, :validate_transfer!)

    submission = on_other_connection { submit(transfer) }
    wait_for(reached)
    approval = on_other_connection do
      Inventory::StockIssueApproval.new(stock_issue_id: issue.id, actor: User.find(issue_approver.id)).approve!
    end
    expect(wait_until_lock_waits("products")).to be_present

    release << true
    expect(result_of(submission)).to be_ok
    result = result_of(approval)
    expect(result).not_to be_ok
    expect(result.error).to match(/pending stock transfers TRF-\d+/)
    expect(StockIssue.find(issue.id)).to be_pending_approval
    expect(reserved).to eq(70)
  end

  it "3. two dispatches of the same transfer post it exactly once", :aggregate_failures do
    transfer = approved(30)
    reached, release = pause_first_call(Inventory::StockTransferLedger, :leg!)

    first = on_other_connection { dispatch(transfer) }
    wait_for(reached) # inside posting, holding the transfer row lock
    second = on_other_connection { dispatch(transfer) }
    expect(wait_until_lock_waits("stock_transfers")).to be_present

    release << true
    expect(result_of(first)).to be_ok
    expect(result_of(second).error).to eq(I18n.t("inventory.stock_transfers.errors.invalid_transition"))
    expect(InventoryMovement.where(source_type: "StockTransfer", source_id: transfer.id).count).to eq(2)
    expect(on_hand).to eq(70)
    expect(transit_on_hand).to eq(30)
    expect(Product.find(product.id).current_stock).to eq(100)
    expect(reserved).to eq(0)
    expect(AuditLog.where(auditable_type: "StockTransfer", auditable_id: transfer.id, action: "dispatch").count).to eq(1)
  end

  it "4. a reservation increase and another submission cannot both take the same stock", :aggregate_failures do
    a = draft(40).tap { |t| expect(submit(t)).to be_ok }
    b = draft(50)
    line = a.items.first
    reached, release = pause_first_call(Inventory::StockAvailability, :validate_transfer!)

    edit = on_other_connection do
      Inventory::StockTransferEditor.new(stock_transfer_id: a.id, actor: User.find(approver.id),
                                         attributes: { items_attributes: { "0" => { id: line.id, quantity: 70 } } }).call
    end
    wait_for(reached)
    submission = on_other_connection { submit(b) }
    expect(wait_until_lock_waits("products")).to be_present

    release << true
    expect(result_of(edit)).to be_ok
    expect(result_of(submission)).not_to be_ok
    expect(StockTransfer.find(a.id).items.sole.quantity).to eq(70)
    expect(StockTransfer.find(b.id)).to be_draft
    expect(reserved).to eq(70)
    expect(on_hand - reserved).to eq(30)
  end

  it "5. a cancellation racing a dispatch neither releases a dispatched reservation nor dispatches a cancelled one", :aggregate_failures do
    transfer = approved(25)
    reached, release = pause_first_call(Inventory::StockTransferLedger, :leg!)

    dispatching = on_other_connection { dispatch(transfer) }
    wait_for(reached)
    cancellation = on_other_connection do
      Inventory::StockTransferCancellation.new(stock_transfer_id: transfer.id, actor: User.find(approver.id), reason: "late").call
    end
    expect(wait_until_lock_waits("stock_transfers")).to be_present

    release << true
    expect(result_of(dispatching)).to be_ok
    expect(result_of(cancellation)).not_to be_ok
    stored = StockTransfer.find(transfer.id)
    expect(stored).to be_in_transit
    expect(stored.cancelled_at).to be_nil
    expect(on_hand).to eq(75)
    expect(reserved).to eq(0)
  end

  it "6. a failed dispatch leaves stock, reservation and status exactly as they were", :aggregate_failures do
    transfer = approved(10)
    allow(Inventory::StockTransferLedger).to receive(:leg!).and_wrap_original do |original, transfer_arg, **kw|
      original.call(transfer_arg, **kw)
      raise ActiveRecord::RecordInvalid, InventoryMovement.new
    end

    expect(result_of(on_other_connection { dispatch(transfer) })).not_to be_ok
    expect(StockTransfer.find(transfer.id)).to be_awaiting_dispatch
    expect(InventoryMovement.where(source_type: "StockTransfer").count).to eq(0)
    expect(on_hand).to eq(100)
    expect(reserved).to eq(10)
    expect(AuditLog.where(auditable_type: "StockTransfer", action: "dispatch").count).to eq(0)
  end

  it "7. a dispatch and a stock issue approval cannot both take the same stock", :aggregate_failures do
    transfer = approved(70)
    issue = business.stock_issues.build(warehouse: source, issued_on: Date.current)
    issue.items.build(product: product, quantity: 40)
    issue = save_stock_issue_in_status!(issue, :pending_approval)
    # The transfer already reserves 70: the issue fits only if it takes no more than 30 — paused dispatch holds the products.
    reached, release = pause_first_call(Inventory::StockAvailability, :validate_transfer!)

    dispatching = on_other_connection { dispatch(transfer) }
    wait_for(reached)
    approval = on_other_connection do
      Inventory::StockIssueApproval.new(stock_issue_id: issue.id, actor: User.find(issue_approver.id)).approve!
    end
    expect(wait_until_lock_waits("products")).to be_present

    release << true
    expect(result_of(dispatching)).to be_ok
    expect(result_of(approval)).not_to be_ok
    expect(StockIssue.find(issue.id)).to be_pending_approval
    expect(on_hand).to eq(30)
    expect(reserved).to eq(0)
  end

  it "8. two receipts of the same units cannot both succeed", :aggregate_failures do
    transfer = approved(10).tap { |t| raise "dispatch" unless dispatch(t).ok? }
    reached, release = pause_first_call(Inventory::StockTransferLedger, :leg!)

    first = on_other_connection { receive_goods(transfer, 10) }
    wait_for(reached)
    second = on_other_connection { receive_goods(transfer, 10) }
    expect(wait_until_lock_waits("stock_transfers")).to be_present

    release << true
    expect(result_of(first)).to be_ok
    expect(result_of(second)).not_to be_ok
    expect(StockTransfer.find(transfer.id)).to be_received
    expect(on_hand(dest)).to eq(10)
    expect(transit_on_hand).to eq(0)
    expect(StockTransferReceipt.where(stock_transfer_id: transfer.id).count).to eq(1)
  end

  it "9. a receipt and a resolution of the same remaining units cannot both succeed", :aggregate_failures do
    transfer = approved(10).tap { |t| raise "dispatch" unless dispatch(t).ok? }
    raise "short receipt" unless receive_goods(transfer, 4, close: true).ok?
    item = StockTransfer.find(transfer.id).items.first
    reached, release = pause_first_call(Inventory::StockTransferLedger, :leg!)

    resolution = on_other_connection do
      Inventory::StockTransferDiscrepancyResolution.new(stock_transfer_id: transfer.id, actor: User.find(approver.id),
                                                        entries: { item.id => { "write_off" => 6 } }, reason: "lost").call
    end
    wait_for(reached)
    second = on_other_connection do
      Inventory::StockTransferDiscrepancyResolution.new(stock_transfer_id: transfer.id, actor: User.find(approver.id),
                                                        entries: { item.id => { "return_to_source" => 6 } }, reason: "found").call
    end
    expect(wait_until_lock_waits("stock_transfers")).to be_present

    release << true
    expect(result_of(resolution)).to be_ok
    expect(result_of(second)).not_to be_ok
    expect(StockTransfer.find(transfer.id)).to be_received
    expect(StockTransferResolution.where(stock_transfer_id: transfer.id).sum(:quantity)).to eq(6)
    expect(transit_on_hand).to eq(0)
    expect(Product.find(product.id).current_stock).to eq(94)
  end

  it "10. concurrent transit provisioning creates exactly one transit warehouse", :aggregate_failures do
    reached, release = pause_first_call(Warehouse, :new)
    first = on_other_connection { Inventory::TransitWarehouse.for!(Business.find(business.id), actor: User.find(approver.id)) }
    wait_for(reached) # inside the advisory lock, before creating
    second = on_other_connection { Inventory::TransitWarehouse.for!(Business.find(business.id), actor: User.find(approver.id)) }
    expect(wait_until_lock_waits("pg_advisory_xact_lock")).to be_present # the second provisioner waits for the first
    release << true
    a = result_of(first)
    b = result_of(second)
    expect(a.id).to eq(b.id)
    expect(Warehouse.where(business_id: business.id, kind: "transit").count).to eq(1)
    expect(AuditLog.where(action: "provision_transit_warehouse").count).to eq(1)
  end
end
