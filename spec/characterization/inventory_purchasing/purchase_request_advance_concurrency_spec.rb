require "rails_helper"

# Characterization (S2 M1) — Purchase Request advance confirmation and reversal
# under real concurrency, with TWO database connections. Pins what the unchanged
# code (`ec8ae59`) does when two operations overlap on one Purchase Request;
# both sides lock the Purchase Request row first (advance confirm / reverse:
# request → advance → custody account; receipt approval: receipt → request), so
# the second always waits and then decides on committed rows. A pass is not proof
# that a race is impossible.
#
# Harness (Queue handshake, no sleeps, bounded waits, empty-database guard and
# truncation) copied from goods_receipt_payments_concurrency_spec.rb (Batch S M1).
# Pause points name only methods that exist before and after S2
# (FinancialSettlementService, Inventory::GoodsReceiptPaymentEffects), so the same
# examples prove the migrated code.
RSpec.describe "Characterization: Purchase Request advance concurrency (two connections, S2 M1)" do
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
  let(:owner)     { create(:user, :super_admin, business: business) }
  let(:recorder)  { create(:user, :super_admin, business: business) }
  let(:confirmer) { create(:user, business: business) }
  let(:other)     { create(:user, business: business) }
  let(:supplier)  { business.suppliers.create!(name: "Nile Beauty") }
  let(:warehouse) { business.warehouses.create!(name: "Main") }
  let(:product)   { business.products.create!(name: "Shampoo", sku: "SH-1", average_cost_price: 121) }
  let(:custody) do
    create(:custody_account, business: business, user: confirmer).tap do |account|
      account.custody_transactions.create!(business: business, txn_type: "top_up", amount: 500)
      account.refresh_balance!
    end
  end

  # 2 × 121 = 242, approved.
  let(:request_record) do
    pr = PurchaseRequest.new(business: business, supplier: supplier, created_by: owner)
    pr.items.build(product: product, quantity: 2, unit_price: 121, source_warehouse: warehouse)
    pr.save!
    pr.update_column(:status, "approved")
    pr
  end

  def recorded_advance(amount = 100)
    Inventory::PurchaseRequestAdvanceRecorder.new(
      purchase_request_id: request_record.id, actor: recorder,
      params: { amount: amount, source_kind: "employee_custody", custody_account_id: custody.id, paid_on: Date.current }
    ).call.advance
  end

  def confirmed_advance
    recorded_advance.tap { |a| expect(confirm(a.id, other)).to be_ok }
  end

  # A pending receipt for one unit (121) from the request, paid by supplier credit.
  def pending_receipt
    receipt = business.goods_receipts.build(warehouse: warehouse, supplier: supplier, purchase_request: request_record,
                                            received_on: Date.current, created_by: owner,
                                            funding_source_kind: "supplier_credit")
    receipt.items.build(product: product, quantity: 1, unit_cost: 121, purchase_request_item: request_record.items.sole)
    receipt.save!
    receipt.update_column(:approval_status, "pending_approval")
    receipt
  end

  def confirm(id, actor) = Inventory::PurchaseRequestAdvanceWorkflow.new(advance_id: id, actor: actor).confirm!
  def reverse(id) = Inventory::PurchaseRequestAdvanceWorkflow.new(advance_id: id, actor: other).reverse!(reason: "refund")
  def approve(id) = Inventory::GoodsReceiptApproval.new(goods_receipt_id: id, actor: other).approve!

  def balance_of(account) = CustodyAccount.find(account.id).current_balance
  def ledger_sum(account) = CustodyTransaction.active.where(custody_account_id: account.id).sum(:amount)
  def request_settlements = FinancialSettlement.where(settleable_type: "PurchaseRequest").order(:id).to_a
  def applications_of(advance_id)
    FinancialSettlement.where(funding_source_type: "PurchaseRequestAdvance", funding_source_id: advance_id)
  end

  it "two confirmations: the second waits on the request row, then is refused — custody is debited once" do
    advance = recorded_advance
    second_actor = create(:user, business: business)
    reached, release = pause_after_first(FinancialSettlementService, :create)

    first = on_other_connection { confirm(advance.id, other) }
    wait_for(reached) # request + advance + account locked, settlement written — not committed

    second = on_other_connection { confirm(advance.id, second_actor) }
    expect(wait_until_lock_waits("%purchase_requests%FOR UPDATE%")).to match(/FOR UPDATE/)
    expect(second.join(0)).to be_nil

    release << true
    expect(result_of(first)).to be_ok
    refused = result_of(second)
    expect([ refused.ok?, refused.error ])
      .to eq([ false, I18n.t("inventory.purchase_request_advances.errors.invalid_transition") ])

    expect(request_settlements.map(&:amount)).to eq([ 100 ])
    expect(CustodyTransaction.where(txn_type: "inventory_purchase").count).to eq(1)
    expect(balance_of(custody)).to eq(400)
    expect(balance_of(custody)).to eq(ledger_sum(custody))
    expect(PurchaseRequestAdvance.find(advance.id).confirmed_by_id).to eq(other.id)
  end

  it "receipt approval applies the advance first: the reversal waits on the request row, then is refused (already applied)" do
    advance = confirmed_advance
    receipt = pending_receipt
    reached, release = pause_after_first(Inventory::GoodsReceiptPaymentEffects, :advance_applied)

    approving = on_other_connection { approve(receipt.id) }
    wait_for(reached) # receipt + request locked, application written — not committed

    reversing = on_other_connection { reverse(advance.id) }
    expect(wait_until_lock_waits("%purchase_requests%FOR UPDATE%")).to match(/FOR UPDATE/)
    expect(reversing.join(0)).to be_nil

    release << true
    expect(result_of(approving)).to be_ok
    refused = result_of(reversing)
    expect([ refused.ok?, refused.error ])
      .to eq([ false, I18n.t("inventory.purchase_request_advances.errors.already_applied") ])

    expect(PurchaseRequestAdvance.find(advance.id)).to be_confirmed
    expect(applications_of(advance.id).sum(:amount)).to eq(100)
    expect(request_settlements.map(&:amount)).to eq([ 100 ])
    expect(CustodyTransaction.where(txn_type: "inventory_purchase_reversal")).to be_empty
    expect(balance_of(custody)).to eq(400)
  end

  it "reversal first: the receipt approval waits on the request row, then applies nothing from the reversed advance" do
    advance = confirmed_advance
    receipt = pending_receipt
    reached, release = pause_after_first(FinancialSettlementService, :reverse)

    reversing = on_other_connection { reverse(advance.id) }
    wait_for(reached) # request + advance locked, reversal settlement written — not committed

    approving = on_other_connection { approve(receipt.id) }
    expect(wait_until_lock_waits("%purchase_requests%FOR UPDATE%")).to match(/FOR UPDATE/)
    expect(approving.join(0)).to be_nil

    release << true
    expect(result_of(reversing)).to be_ok
    expect(result_of(approving)).to be_ok

    expect(PurchaseRequestAdvance.find(advance.id)).to be_reversed
    expect(applications_of(advance.id)).to be_empty
    expect(request_settlements.map(&:amount)).to eq([ 100, -100 ])
    expect(balance_of(custody)).to eq(500)
    expect(balance_of(custody)).to eq(ledger_sum(custody))
    expect(GoodsReceipt.find(receipt.id).approval_status).to eq("approved")
  end
end
