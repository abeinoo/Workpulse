require "rails_helper"

# Characterization (Batch S M1) — goods-receipt payment writes under real
# concurrency, with TWO database connections (a second connection is the only
# thing a row lock can block). Pins what the current code does when two
# operations overlap; it does not decide what they should do. Where the code is
# suspected unsafe (BUG-015, docs/quality/deferred-bugs.md) the example asserts
# the SAFE invariant, so a reproduction shows up as a failure — never as accepted
# behaviour. A pass is not proof that a race is impossible.
#
# Deterministic: one operation is paused (blocking Queue handshake, no sleeps) at
# a known point while holding its locks, uncommitted; the other is observed
# waiting on a lock (pg_stat_activity); every wait is bounded.
#
# Not transactional (the other connection must see committed rows): every
# example refuses to start unless the test database is empty and truncates every
# table afterwards — the harness of spec/services/requests/advance_payment_concurrency_spec.rb.
#
# Approval and single reversal cannot overlap on ONE receipt (a reversal needs an
# approved receipt, an approval a pending one); "approval vs reversal" is
# therefore two receipts paid from the same custody account.
RSpec.describe "Characterization: goods-receipt payment concurrency (two connections, Batch S M1)" do
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

  # Bounded wait until another backend is blocked on a lock while running a
  # statement matching `pattern`. Returns the waiting statement.
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

  # Pauses the FIRST call of `method` on `target` right after it ran, until released.
  def pause_after_first(target, method)
    reached = Queue.new
    release = Queue.new
    calls   = 0
    allow(target).to receive(method).and_wrap_original do |original, *args, **kwargs, &blk|
      calls += 1
      outcome = original.call(*args, **kwargs, &blk)
      if calls == 1
        reached << true
        release.pop
      end
      outcome
    end
    @releases = (@releases || []) << release
    [ reached, release ]
  end

  let(:business)  { create(:business) }
  let(:requester) { create(:user, business: business) }
  let(:approver)  { create(:user, business: business) }
  let(:reverser)  { create(:user, business: business) }
  let(:voider)    { create(:user, business: business) }
  let(:warehouse) { business.warehouses.create!(name: "Main") }
  let(:product)   { business.products.create!(name: "Shampoo", sku: "SH-1", initial_cost_price: 0, average_cost_price: 0) }
  let(:custody) do
    create(:custody_account, business: business, user: requester).tap do |account|
      account.custody_transactions.create!(business: business, txn_type: "top_up", amount: 1000)
      account.refresh_balance!
    end
  end

  # 2 × 125 = 250 from the custody account, pending approval.
  def pending_receipt
    receipt = business.goods_receipts.build(warehouse: warehouse, received_on: Date.current, created_by: requester,
                                            funding_source_kind: "employee_custody", funding_source: custody)
    receipt.items.build(product: product, quantity: 2, unit_cost: 125)
    receipt.save!
    receipt.update_column(:approval_status, "pending_approval")
    receipt
  end

  # Each operation loads its own copy on its own connection, as a controller would.
  def approve(id) = Inventory::GoodsReceiptApproval.new(goods_receipt_id: id, actor: approver).approve!
  def void(id) = Inventory::GoodsReceiptVoider.new(goods_receipt_id: id, actor: voider, reason: "duplicate").call
  def reverse(id, settlement_id)
    Inventory::GoodsReceiptSettlementReverser.new(goods_receipt_id: id, settlement_id: settlement_id, actor: reverser,
                                                  reason: "wrong receipt").call
  end

  def settlements_of(id) = FinancialSettlement.where(settleable_type: "GoodsReceipt", settleable_id: id).order(:id).to_a
  def ledger_sum(account) = CustodyTransaction.active.where(custody_account_id: account.id).sum(:amount)
  def balance_of(account) = CustodyAccount.find(account.id).current_balance

  it "void first, approval second: the approval waits for the receipt row, then is refused — nothing is paid" do
    receipt = pending_receipt
    reached, release = pause_after_first(FinancialSettlementService, :reverse_all)

    voiding = on_other_connection { void(receipt.id) }
    wait_for(reached) # receipt row updated (voided, approval cancelled) and locked — not committed

    approving = on_other_connection { approve(receipt.id) }
    expect(wait_until_lock_waits("%goods_receipts%FOR UPDATE%")).to match(/FOR UPDATE/)
    expect(approving.join(0)).to be_nil

    release << true
    expect(result_of(voiding)).to be_ok

    refused = result_of(approving)
    expect([ refused.ok?, refused.error ])
      .to eq([ false, I18n.t("inventory.goods_receipts.errors.invalid_approval_transition") ])

    final = GoodsReceipt.find(receipt.id)
    expect([ final.voided?, final.approval_status ]).to eq([ true, "cancelled" ])
    expect(settlements_of(receipt.id)).to be_empty
    expect(balance_of(custody)).to eq(1000)
    expect(AuditLog.where(auditable: final, action: "approve")).to be_empty
  end

  it "approval first, void second: the void waits for the receipt row; the approved status must survive (BUG-015)" do
    receipt = pending_receipt
    reached, release = pause_after_first(FinancialSettlementService, :create)

    approving = on_other_connection { approve(receipt.id) }
    wait_for(reached) # receipt row locked, approval payment settlement written — not committed

    voiding = on_other_connection { void(receipt.id) }
    expect(wait_until_lock_waits("%goods_receipts%")).to be_present
    expect(voiding.join(0)).to be_nil

    release << true
    expect(result_of(approving)).to be_ok
    voided = result_of(voiding)

    final = GoodsReceipt.find(receipt.id)
    payment, *reversals = settlements_of(receipt.id)
    # Money: whatever the void did, the custody ledger and the cached balance agree,
    # and every settlement in effect was reversed with a custody credit.
    expect(balance_of(custody)).to eq(ledger_sum(custody))
    expect(settlements_of(receipt.id).sum(&:amount)).to eq(0) if voided.ok?
    expect(balance_of(custody)).to eq(1000) if voided.ok?
    expect(payment.amount).to eq(250)
    expect(reversals.map(&:reverses_settlement_id)).to eq(voided.ok? ? [ payment.id ] : [])
    # Status integrity (the safe invariant): a decided approval is kept as history.
    audits = AuditLog.where(auditable: final).order(:id).map { [ _1.action, _1.changes_json, _1.metadata ] }
    expect(final.approval_status).to eq("approved"), <<~MSG
      BUG-015 reproduced: approved, then voided by a void that waited on the receipt row — approval_status is
      #{final.approval_status.inspect}; voided=#{final.voided?}; settlements #{settlements_of(receipt.id).map { [ _1.id, _1.amount.to_s, _1.reverses_settlement_id ] }.inspect};
      custody balance #{balance_of(custody)} (ledger #{ledger_sum(custody)}); audits #{audits.inspect}
    MSG
  end

  it "approval vs reversal on one custody account: the reversal's credit waits for the account; both commit, balance = ledger" do
    paid = pending_receipt
    expect(approve(paid.id)).to be_ok
    payment = settlements_of(paid.id).sole
    other = pending_receipt
    reached, release = pause_after_first(FinancialSettlementService, :create)

    approving = on_other_connection { approve(other.id) } # locks other receipt → custody account, then pauses
    wait_for(reached)

    reversing = on_other_connection { reverse(paid.id, payment.id) }
    expect(wait_until_lock_waits("%custody_accounts%FOR UPDATE%")).to match(/FOR UPDATE/)
    expect(reversing.join(0)).to be_nil

    release << true
    expect(result_of(approving)).to be_ok
    expect(result_of(reversing)).to be_ok

    expect(settlements_of(paid.id).map(&:amount)).to eq([ 250, -250 ])
    expect(settlements_of(other.id).map(&:amount)).to eq([ 250 ])
    expect(CustodyTransaction.where(custody_account_id: custody.id).order(:id).map { [ _1.txn_type, _1.amount ] })
      .to eq([ [ "top_up", 1000 ], [ "inventory_purchase", -250 ], [ "inventory_purchase", -250 ],
               [ "inventory_purchase_reversal", 250 ] ])
    expect(balance_of(custody)).to eq(750)
    expect(balance_of(custody)).to eq(ledger_sum(custody))
  end
end
