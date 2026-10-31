require "rails_helper"

# BUG-016 (docs/quality/deferred-bugs.md) — two voids of the same goods receipt,
# proven with TWO database connections (a second connection is the only thing a
# row lock can block). The first void is paused (blocking Queue handshake, no
# sleeps) inside its transaction after its stock reversal and void update, before
# its settlement reversals; the second void is then started. Each example asserts
# the SAFE outcome: one stock reversal, one set of settlement reversals, one void
# audit, the second void refused as already voided.
#
# Not transactional (the other connection must see committed rows): every
# example refuses to start unless the test database is empty and truncates every
# table afterwards — the harness of spec/services/requests/advance_payment_concurrency_spec.rb.
RSpec.describe "GoodsReceipt void concurrency (two connections, BUG-016)" do
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
    problems.concat(open_connection_problems) if survivors.empty?

    truncated = @guard_passed && problems.empty?
    if truncated
      conn = ActiveRecord::Base.connection
      conn.truncate_tables(*self.class.data_tables(conn))
    end

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

  def open_connection_problems
    problems = []
    busy = ActiveRecord::Base.connection_pool.stat[:busy]
    problems << "#{busy - 1} worker connection(s) still checked out" if busy > 1

    others = ActiveRecord::Base.connection.select_value(<<~SQL).to_i
      SELECT COUNT(*) FROM pg_stat_activity
      WHERE datname = current_database() AND pid <> pg_backend_pid()
        AND state IN ('active', 'idle in transaction', 'idle in transaction (aborted)')
        AND backend_type = 'client backend'
    SQL
    problems << "#{others} other database session(s) still active or in a transaction" if others.positive?
    problems
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

  # Pauses the first FinancialSettlementService.reverse_all (the void's step after
  # its stock reversal and void update) until released; later calls run through.
  def pause_first_void
    reached = Queue.new
    release = Queue.new
    calls   = 0
    allow(FinancialSettlementService).to receive(:reverse_all).and_wrap_original do |original, **kwargs|
      calls += 1
      if calls == 1
        reached << true
        release.pop
      end
      original.call(**kwargs)
    end
    @releases = (@releases || []) << release
    [ reached, release ]
  end

  let(:business) { create(:business) }
  let(:actor)    { create(:user, :super_admin, business: business) }
  let(:other)    { create(:user, :super_admin, business: business) }
  let(:warehouse) { business.warehouses.create!(name: "Main") }
  let(:product) do
    business.products.create!(name: "Hair Color", sku: "HC-1", initial_cost_price: 0, average_cost_price: 0)
  end
  let(:custody) do
    create(:custody_account, business: business).tap do |account|
      account.custody_transactions.create!(business: business, txn_type: "top_up", amount: 1000)
      account.refresh_balance!
    end
  end

  # 10 × 50 = 500 from custody, approved (payment) and optionally confirmed (stock posted).
  def receipt(confirmed:)
    r = business.goods_receipts.build(warehouse: warehouse, received_on: Date.current,
                                      funding_source_kind: "employee_custody", funding_source: custody)
    r.items.build(product: product, quantity: 10, unit_cost: 50)
    r.save!
    r.update_column(:approval_status, "pending_approval")
    raise "approval failed" unless Inventory::GoodsReceiptApproval.new(goods_receipt_id: r.id, actor: actor).approve!.ok?
    Inventory::GoodsReceiptConfirmationService.new(goods_receipt_id: r.id, actor: actor).call if confirmed
    GoodsReceipt.find(r.id)
  end

  def void(id, by:) = Inventory::GoodsReceiptVoider.new(goods_receipt_id: id, actor: by, reason: "duplicate").call

  def reversal_movements(r) = InventoryMovement.where(source_type: "GoodsReceipt", source_id: r.id, reason: "reversal")
  def settlements_of(r) = FinancialSettlement.where(settleable_type: "GoodsReceipt", settleable_id: r.id)
  def void_audits(r) = AuditLog.where(auditable_type: "GoodsReceipt", auditable_id: r.id, action: "void")

  def race_two_voids(r)
    reached, release = pause_first_void
    first = on_other_connection { void(r.id, by: actor) }
    wait_for(reached) # stock reversed (if confirmed) and receipt marked voided — not committed

    second = on_other_connection { void(r.id, by: other) }
    expect(wait_until_lock_waits("%goods_receipts%")).to be_present
    expect(second.join(0)).to be_nil

    release << true
    [ result_of(first), result_of(second) ]
  end

  it "confirmed receipt: one stock reversal — the second void is refused; stock, cost and custody are restored once", :aggregate_failures do
    r = receipt(confirmed: true)
    expect(product.reload.current_stock).to eq(10)

    first, second = race_two_voids(r)

    expect(first).to be_ok
    expect([ second.ok?, second.error ]).to eq([ false, r.errors.generate_message(:base, :already_voided) ])
    expect(reversal_movements(r).count).to eq(1)
    expect(product.reload.current_stock).to eq(0)
    expect(product.average_cost_price).to eq(0)
    expect(settlements_of(r).order(:id).map(&:amount)).to eq([ 500, -500 ])
    expect(CustodyAccount.find(custody.id).current_balance).to eq(1000)
    expect(void_audits(r).pluck(:actor_id)).to eq([ actor.id ])
    expect(GoodsReceipt.find(r.id).voided_by_id).to eq(actor.id)
  end

  it "approved, unconfirmed receipt: one void — the second is refused; the payment is reversed once", :aggregate_failures do
    r = receipt(confirmed: false)

    first, second = race_two_voids(r)

    expect(first).to be_ok
    expect([ second.ok?, second.error ]).to eq([ false, r.errors.generate_message(:base, :already_voided) ])
    expect(reversal_movements(r)).to be_empty
    expect(settlements_of(r).order(:id).map(&:amount)).to eq([ 500, -500 ])
    expect(CustodyAccount.find(custody.id).current_balance).to eq(1000)
    expect(void_audits(r).pluck(:actor_id)).to eq([ actor.id ])
    expect(GoodsReceipt.find(r.id).voided_by_id).to eq(actor.id)
  end
end
