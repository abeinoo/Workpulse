require "rails_helper"

# Stock count approval / reopen under real concurrency — TWO database
# connections (a second connection is the only thing a row lock can block).
# The first operation is paused (blocking Queue handshake, no sleeps) inside its
# transaction on its first ProductCostRecalculator#recompute! — i.e. after its
# movements are written, before commit, while it holds the count and product
# row locks — and the competing operation is started and observed waiting on a
# lock (pg_stat_activity). Each example asserts the SAFE outcome.
#
# Not transactional: refuses to start unless the test database is empty and
# truncates every table afterwards — the harness of
# spec/services/inventory/document_voider_concurrency_spec.rb.
RSpec.describe "Stock count concurrency (two connections)" do
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

  # Pauses the first cost recompute (inside the first operation's transaction,
  # after its movements) until released.
  def pause_first_recompute
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

  let(:business)  { create(:business) }
  let(:counter)   { user_with_stock_permissions(business, :view_inventory, :manage_stock_counts, name: "Counter") }
  let(:approver)  { user_with_stock_permissions(business, :view_inventory, :post_stock_counts, name: "Approver") }
  let(:approver2) { user_with_stock_permissions(business, :view_inventory, :post_stock_counts, name: "Approver 2") }
  let(:main)      { business.warehouses.create!(name: "Main") }
  let(:branch)    { business.branches.create!(name: "Branch", active: true) }
  let(:product)   { business.products.create!(name: "Shampoo", sku: "SH-1", initial_cost_price: 5, average_cost_price: 5) }

  def receive!(qty)
    r = business.goods_receipts.build(warehouse: main, received_on: Date.current)
    r.items.build(product: product, quantity: qty, unit_cost: 5)
    expect(Inventory::GoodsReceiptPoster.new(r).call.ok?).to be(true)
  end

  def approved_issue(qty)
    issue = business.stock_issues.build(warehouse: main, branch: branch, issued_on: Date.current)
    issue.items.build(product: product, quantity: qty)
    save_stock_issue_in_status!(issue, :approved)
  end

  def completed_count(quantity)
    record_stock_count!(business: business, warehouse: main, counter: counter, lines: [ [ product, quantity ] ], complete: true)
  end

  def approve(count, actor) = Inventory::StockCountApprover.new(stock_count_id: count.id, actor: actor).call
  def reopen(count, actor) = Inventory::StockCountReopener.new(stock_count_id: count.id, actor: actor, reason: "recount").call
  def stock = product.stock_in(main)

  it "two simultaneous approvals post exactly one adjustment", :aggregate_failures do
    receive!(10)
    count = completed_count(7)
    reached, release = pause_first_recompute

    first = on_other_connection { approve(count, approver) }
    wait_for(reached)                                  # adjustment + movement written, not committed
    second = on_other_connection { approve(count, approver2) }
    expect(wait_until_lock_waits("stock_counts")).to be_present
    expect(second.join(0)).to be_nil

    release << true
    results = [ result_of(first), result_of(second) ]
    expect(results.map(&:ok?)).to eq([ true, false ])
    expect(results.last.error).to eq(I18n.t("inventory.stock_counts.errors.not_completed"))
    expect(StockAdjustment.where(stock_count_id: count.id).count).to eq(1)
    expect(InventoryMovement.where(source_type: "StockAdjustment").count).to eq(1)
    expect(stock).to eq(7)
    expect(count.reload.approved_by_id).to eq(approver.id)
  end

  it "two simultaneous reopens reverse the adjustment exactly once", :aggregate_failures do
    receive!(10)
    count = completed_count(7)
    expect(approve(count, approver).ok?).to be(true)
    reached, release = pause_first_recompute

    first = on_other_connection { reopen(count, approver) }
    wait_for(reached)                                  # reversal written, not committed
    second = on_other_connection { reopen(count, approver2) }
    expect(wait_until_lock_waits("stock_counts")).to be_present

    release << true
    results = [ result_of(first), result_of(second) ]
    expect(results.map(&:ok?)).to eq([ true, false ])
    expect(InventoryMovement.where(reason: "reversal").count).to eq(1)
    expect(stock).to eq(10)
    expect(count.reload).to be_in_progress
  end

  it "an approval racing a stock issue confirmation never oversells", :aggregate_failures do
    receive!(10)
    issue = approved_issue(9)                          # reserved 9 of 10
    count = completed_count(8)                         # shortage −2 → 8 left
    reached, release = pause_first_recompute

    approval = on_other_connection { approve(count, approver) }
    wait_for(reached)                                  # holds the product lock
    confirmation = on_other_connection do
      Inventory::StockIssueConfirmationService.new(stock_issue_id: issue.id, actor: approver2).call
    end
    expect(wait_until_lock_waits("products")).to be_present

    release << true
    expect(result_of(approval).ok?).to be(true)
    expect(result_of(confirmation).ok?).to be(false)   # reads the committed 8 < 9
    expect(stock).to eq(8)
    expect(issue.reload).to be_approved
  end

  it "an approval racing a receipt keeps the receipt (counted − baseline, not live stock)", :aggregate_failures do
    receive!(10)
    count = completed_count(7)                         # −3
    reached, release = pause_first_recompute

    approval = on_other_connection { approve(count, approver) }
    wait_for(reached)                                  # −3 written, not committed
    receipt = on_other_connection do                   # +10 posted after the count, during approval
      r = business.goods_receipts.build(warehouse: main, received_on: Date.current)
      r.items.build(product: product, quantity: 10, unit_cost: 5)
      Inventory::GoodsReceiptPoster.new(r).call
    end
    # The receipt line's product FK check (FOR KEY SHARE) waits on the approval's product lock.
    expect(wait_until_lock_waits("goods_receipt_items")).to be_present

    release << true
    expect(result_of(approval).ok?).to be(true)
    expect(result_of(receipt).ok?).to be(true)
    expect(stock).to eq(17)                            # 10 − 3 + 10: the receipt is not "counted away"
  end

  it "a reopen reversal racing a stock issue confirmation never oversells", :aggregate_failures do
    receive!(10)
    count = completed_count(15)                        # overage +5 → 15
    expect(approve(count, approver).ok?).to be(true)
    issue = approved_issue(12)                         # reserved 12 of 15
    reached, release = pause_first_recompute

    reopening = on_other_connection { reopen(count, approver) }
    wait_for(reached)                                  # reversal OUT 5 written, holds the product lock
    confirmation = on_other_connection do
      Inventory::StockIssueConfirmationService.new(stock_issue_id: issue.id, actor: approver2).call
    end
    expect(wait_until_lock_waits("products")).to be_present

    release << true
    expect(result_of(reopening).ok?).to be(true)
    expect(result_of(confirmation).ok?).to be(false)   # 10 left < 12
    expect(stock).to eq(10)
  end
end
