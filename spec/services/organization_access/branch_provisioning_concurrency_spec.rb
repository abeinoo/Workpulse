require "rails_helper"

# Branch warehouse provisioning under real concurrency — TWO database
# connections. The first operation is paused (blocking Queue handshake, no
# sleeps) inside its transaction while it holds its locks; the competing one is
# started and observed waiting on a lock (pg_stat_activity). Each example
# asserts the SAFE outcome: exactly one warehouse per sales branch, never one
# for a non-sales branch, never two warehouses with the same name.
#
# Lock order exercised: business -> branch -> warehouse name lock, everywhere —
# OrganizationAccess::CreateBranch / UpdateBranch, Inventory::WarehouseManager#create
# for a branch warehouse, and DeactivateBranch / DeleteBranch (business ->
# branch). No path inverts it, so none of these races can deadlock.
#
# Not transactional: refuses to start unless the test database is empty and
# truncates every table afterwards — the harness of
# spec/services/inventory/stock_count_concurrency_spec.rb.
RSpec.describe "Branch warehouse provisioning concurrency (two connections)" do
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

  def wait_until_lock_waits(fragment)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
    loop do
      query = ActiveRecord::Base.connection.select_value(<<~SQL)
        SELECT query FROM pg_stat_activity
        WHERE datname = current_database() AND pid <> pg_backend_pid()
          AND wait_event_type = 'Lock' AND query ILIKE #{ActiveRecord::Base.connection.quote("%#{fragment}%")}
        LIMIT 1
      SQL
      return query if query
      raise "no backend waited on a lock for #{fragment} within 10 s" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      Thread.pass
    end
  end

  def handshake
    reached = Queue.new
    release = Queue.new
    @releases = (@releases || []) << release
    [ reached, release ]
  end

  # Pauses the first warehouse audit write — i.e. after the warehouse INSERT,
  # before COMMIT, while every lock of that operation is held.
  def pause_first_warehouse_audit
    reached, release = handshake
    calls = 0
    allow_any_instance_of(Inventory::WarehouseManager).to receive(:log_audit!).and_wrap_original do |original, **kwargs|
      calls += 1
      if calls == 1
        reached << true
        release.pop
      end
      original.call(**kwargs)
    end
    [ reached, release ]
  end

  # Pauses the first Branch#save after it wrote (branch row locked, not committed).
  def pause_first_branch_save
    reached, release = handshake
    calls = 0
    allow_any_instance_of(Branch).to receive(:save).and_wrap_original do |original, *args, **kwargs|
      saved = original.call(*args, **kwargs)
      calls += 1
      if calls == 1
        reached << true
        release.pop
      end
      saved
    end
    [ reached, release ]
  end

  # Created eagerly on the main connection — nothing is built inside a worker.
  let!(:business)  { create(:business) }
  let!(:admin)     { user_with_stock_permissions(business, :manage_branches, name: "Branch admin") }
  let!(:admin2)    { user_with_stock_permissions(business, :manage_branches, name: "Branch admin 2") }
  let!(:inventory) { user_with_stock_permissions(business, :view_inventory, :manage_inventory, name: "Inventory") }
  let!(:laundry)   { create(:branch, business: business, name: "Wash", branch_type: "laundry") }
  let!(:sales)     { create(:branch, business: business, name: "Nasr", branch_type: "sales") }

  def update_branch(branch_id, actor, **attributes)
    OrganizationAccess::UpdateBranch.new(branch_id, actor: actor, attributes: attributes.transform_keys(&:to_s)).call
  end

  def warehouse_audits = AuditLog.where(auditable_type: "Warehouse", action: "create")

  it "two simultaneous non-sales -> sales changes provision exactly one warehouse", :aggregate_failures do
    branch_id = laundry.id
    reached, release = pause_first_warehouse_audit

    first = on_other_connection { update_branch(branch_id, admin, branch_type: "sales") }
    wait_for(reached)
    second = on_other_connection { update_branch(branch_id, admin2, branch_type: "sales") }
    expect(wait_until_lock_waits("businesses")).to be_present
    expect(second.join(0)).to be_nil

    release << true
    expect([ result_of(first), result_of(second) ].map(&:ok?)).to eq([ true, true ])
    expect(Warehouse.where(branch_id: branch_id).count).to eq(1)
    expect(warehouse_audits.count).to eq(1)
    expect(Branch.find(branch_id)).to be_branch_type_sales
  end

  it "branch provisioning racing a direct branch-warehouse creation leaves exactly one", :aggregate_failures do
    branch_id = laundry.id
    reached, release = pause_first_warehouse_audit

    provisioning = on_other_connection { update_branch(branch_id, admin, branch_type: "sales") }
    wait_for(reached)
    direct = on_other_connection do
      Inventory::WarehouseManager.new(actor: inventory).create(kind: "branch", name: "Wash direct", branch_id: branch_id)
    end
    expect(wait_until_lock_waits("businesses")).to be_present # business -> branch: waits at the business row first

    release << true
    expect(result_of(provisioning)).to be_ok
    result = result_of(direct)
    expect(result.code).to eq(:branch_already_has_warehouse)
    expect(Warehouse.where(branch_id: branch_id).pluck(:name)).to eq([ "Wash – المخزن" ])
  end

  it "a branch-warehouse creation racing a sales -> non-sales change creates nothing", :aggregate_failures do
    branch_id = sales.id
    reached, release = pause_first_branch_save

    change = on_other_connection { update_branch(branch_id, admin, branch_type: "laundry") }
    wait_for(reached)
    direct = on_other_connection do
      Inventory::WarehouseManager.new(actor: inventory).create(kind: "branch", name: "Nasr direct", branch_id: branch_id)
    end
    expect(wait_until_lock_waits("businesses")).to be_present

    release << true
    expect(result_of(change)).to be_ok
    result = result_of(direct)
    expect(result.code).to eq(:invalid)
    expect(result.warehouse.errors.of_kind?(:branch, :not_sales_branch)).to be(true)
    expect(Warehouse.where(branch_id: branch_id)).to be_empty
  end

  it "provisioning racing a sales -> non-sales change keeps the provisioned warehouse", :aggregate_failures do
    branch_id = laundry.id
    reached, release = pause_first_warehouse_audit

    to_sales = on_other_connection { update_branch(branch_id, admin, branch_type: "sales") }
    wait_for(reached)
    to_laundry = on_other_connection { update_branch(branch_id, admin2, branch_type: "laundry") }
    expect(wait_until_lock_waits("businesses")).to be_present

    release << true
    expect([ result_of(to_sales), result_of(to_laundry) ].map(&:ok?)).to eq([ true, true ])
    expect(Branch.find(branch_id)).to be_branch_type_laundry
    expect(Warehouse.where(branch_id: branch_id, kind: "branch").count).to eq(1) # kept, never deleted
  end

  it "a retry after a rolled-back provisioning provisions exactly once", :aggregate_failures do
    branch_id = laundry.id
    fail_audit_writes!(:create)

    failed = update_branch(branch_id, admin, branch_type: "sales")
    expect(failed.error).to eq(:warehouse_provisioning_failed)
    expect(Branch.find(branch_id)).to be_branch_type_laundry # committed state: nothing happened
    expect(Warehouse.where(branch_id: branch_id)).to be_empty

    allow(AuditLog).to receive(:create!).and_call_original
    expect(update_branch(branch_id, admin, branch_type: "sales")).to be_ok
    expect(update_branch(branch_id, admin, branch_type: "sales")).to be_ok # an unchanged retry
    expect(Warehouse.where(branch_id: branch_id).count).to eq(1)
    expect(warehouse_audits.count).to eq(1)
  end

  it "two simultaneous creations of the same warehouse name leave one (advisory name lock)", :aggregate_failures do
    reached, release = pause_first_warehouse_audit

    first  = on_other_connection { Inventory::WarehouseManager.new(actor: inventory).create(kind: "central", name: "Main") }
    wait_for(reached)
    second = on_other_connection { Inventory::WarehouseManager.new(actor: inventory).create(kind: "central", name: "MAIN") }
    expect(wait_until_lock_waits("pg_advisory_xact_lock")).to be_present

    release << true
    expect(result_of(first)).to be_ok
    expect(result_of(second).code).to eq(:name_taken)
    expect(Warehouse.where("LOWER(name) = 'main'").count).to eq(1)
  end

  # Pauses the first branch-warehouse creation after its business -> branch
  # locks, before its INSERT — the window that deadlocked when the branch was
  # locked before the business (review finding C1).
  def pause_first_warehouse_insert
    reached, release = handshake
    calls = 0
    allow_any_instance_of(Inventory::WarehouseManager).to receive(:persist_new!).and_wrap_original do |original, *args, **kwargs|
      calls += 1
      if calls == 1
        reached << true
        release.pop
      end
      original.call(*args, **kwargs)
    end
    [ reached, release ]
  end

  def create_branch_warehouse(branch_id)
    Inventory::WarehouseManager.new(actor: inventory).create(kind: "branch", name: "Nasr direct", branch_id: branch_id)
  end

  it "a branch-warehouse creation holding its locks makes DeactivateBranch wait — no deadlock", :aggregate_failures do
    branch_id = sales.id
    reached, release = pause_first_warehouse_insert

    creation = on_other_connection { create_branch_warehouse(branch_id) }
    wait_for(reached) # holds business (NO KEY UPDATE) + branch (SHARE), not yet inserted
    deactivation = on_other_connection do
      OrganizationAccess::DeactivateBranch.new(branch_id, actor: admin2, reason: "closing").call
    end
    expect(wait_until_lock_waits("businesses")).to be_present

    release << true
    expect(result_of(creation)).to be_ok
    expect(result_of(deactivation)).to be_ok
    expect(Branch.find(branch_id).active).to be(false)
    expect(Warehouse.where(branch_id: branch_id).count).to eq(1)
  end

  it "DeactivateBranch holding its locks makes a branch-warehouse creation wait — no deadlock", :aggregate_failures do
    branch_id = sales.id
    reached, release = handshake
    allow(OrganizationAccess::MembershipProvider).to receive(:effective_assignments_at?).and_wrap_original do |original, *args, **kwargs|
      reached << true # business + branch FOR UPDATE held
      release.pop
      original.call(*args, **kwargs)
    end

    deactivation = on_other_connection do
      OrganizationAccess::DeactivateBranch.new(branch_id, actor: admin2, reason: "closing").call
    end
    wait_for(reached)
    creation = on_other_connection { create_branch_warehouse(branch_id) }
    expect(wait_until_lock_waits("businesses")).to be_present

    release << true
    expect(result_of(deactivation)).to be_ok
    expect(result_of(creation)).to be_ok # the branch is still a sales branch (inactive) — valid
    expect(Branch.find(branch_id).active).to be(false)
    expect(Warehouse.where(branch_id: branch_id).count).to eq(1)
  end

  it "a branch-warehouse creation racing DeleteBranch: no deadlock, and the branch keeps its warehouse", :aggregate_failures do
    branch_id = sales.id
    reached, release = pause_first_warehouse_insert

    creation = on_other_connection { create_branch_warehouse(branch_id) }
    wait_for(reached)
    deletion = on_other_connection { OrganizationAccess::DeleteBranch.new(branch_id, actor: admin2, reason: "never used").call }
    expect(wait_until_lock_waits("businesses")).to be_present

    release << true
    expect(result_of(creation)).to be_ok
    expect(result_of(deletion).error).to eq(:has_history) # the warehouse now references it
    expect(Branch.exists?(branch_id)).to be(true)
    expect(Warehouse.where(branch_id: branch_id).count).to eq(1)
  end

  it "names PostgreSQL considers equal share one effective name lock (review finding C2)", :aggregate_failures do
    business_id = business.id
    reached, release = handshake

    holder = on_other_connection do
      Warehouse.transaction do
        Warehouse.connection.execute("SELECT pg_advisory_xact_lock(#{Warehouse.name_lock_key_sql(business_id, 'ÄRZTE Lager')})")
        reached << true
        release.pop
      end
      :released
    end
    wait_for(reached)

    conn = ActiveRecord::Base.connection
    try_lock = lambda do |name, for_business = business_id|
      conn.select_value("SELECT pg_try_advisory_xact_lock(#{Warehouse.name_lock_key_sql(for_business, name)})")
    end
    # "Equal" is whatever the uniqueness validation's LOWER() says in THIS
    # database's collation (the test database is collation C, where LOWER()
    # folds ASCII only) — the lock must agree with it exactly, either way.
    db_equal = ->(name) { conn.select_value("SELECT LOWER(#{conn.quote(name)}) = LOWER(#{conn.quote('ÄRZTE Lager')})") }

    %w[Ärzte\ LAGER Ärzte\ lager ärzte\ lager ärzte\ LAGER].each do |name|
      # Equal to the held name -> the same lock (cannot be taken); different -> a free lock.
      expect(try_lock.call(name)).to eq(!db_equal.call(name)), "#{name}: db_equal=#{db_equal.call(name)}"
    end
    expect(db_equal.call("Ärzte LAGER")).to be(true) # at least one equal pair is exercised in every collation
    expect(try_lock.call("ÄRZTE Lager", business_id + 1)).to be(true) # another business: another lock

    release << true
    expect(result_of(holder)).to eq(:released)
  end

  # PR 4 — Inventory::BranchWarehouseBackfill against the branch lifecycle.
  def backfill(branch_id, actor = admin)
    Inventory::BranchWarehouseBackfill.new(actor: actor, approved_business_ids: [ business.id ]).execute(branch_ids: [ branch_id ]).sole
  end

  it "the backfill waits for a sales -> non-sales change holding the branch, then refuses it", :aggregate_failures do
    branch_id = sales.id
    reached, release = pause_first_branch_save

    change = on_other_connection { update_branch(branch_id, admin, branch_type: "laundry") }
    wait_for(reached)
    run = on_other_connection { backfill(branch_id, admin2) }
    expect(wait_until_lock_waits("businesses")).to be_present

    release << true
    expect(result_of(change)).to be_ok
    outcome = result_of(run)
    expect(outcome).to have_attributes(status: "FAILED", reason: "NOT_ELIGIBLE: not a sales branch (laundry)")
    expect(Warehouse.where(branch_id: branch_id)).to be_empty
  end

  it "a sales -> non-sales change waits for the backfill, which commits; the warehouse is kept", :aggregate_failures do
    branch_id = sales.id
    reached, release = pause_first_warehouse_audit

    run = on_other_connection { backfill(branch_id) }
    wait_for(reached)
    change = on_other_connection { update_branch(branch_id, admin2, branch_type: "laundry") }
    expect(wait_until_lock_waits("businesses")).to be_present

    release << true
    expect(result_of(run).status).to eq("CREATED")
    expect(result_of(change)).to be_ok
    expect(Branch.find(branch_id)).to be_branch_type_laundry
    expect(Warehouse.where(branch_id: branch_id, kind: "branch").count).to eq(1)
  end

  it "two simultaneous backfills of one branch create exactly one warehouse and one audit entry", :aggregate_failures do
    branch_id = sales.id
    reached, release = pause_first_warehouse_audit

    first = on_other_connection { backfill(branch_id) }
    wait_for(reached)
    second = on_other_connection { backfill(branch_id, admin2) }
    expect(wait_until_lock_waits("businesses")).to be_present

    release << true
    expect([ result_of(first), result_of(second) ].map(&:status)).to eq(%w[CREATED ALREADY_PROVISIONED])
    expect(Warehouse.where(branch_id: branch_id).count).to eq(1)
    expect(warehouse_audits.count).to eq(1)
    expect(warehouse_audits.sole.metadata["source"]).to eq("branch_backfill")
  end

  it "a new sales branch racing a central warehouse of the same name: the later one fails, nothing duplicates", :aggregate_failures do
    reached, release = pause_first_warehouse_audit

    branch = on_other_connection do
      OrganizationAccess::CreateBranch.new(actor: admin, attributes: { "name" => "Shubra", "branch_type" => "sales" }).call
    end
    wait_for(reached)
    central = on_other_connection do
      Inventory::WarehouseManager.new(actor: inventory).create(kind: "central", name: "Shubra – المخزن")
    end
    expect(wait_until_lock_waits("pg_advisory_xact_lock")).to be_present

    release << true
    expect(result_of(branch)).to be_ok
    expect(result_of(central).code).to eq(:name_taken)
    expect(Warehouse.where(name: "Shubra – المخزن").pluck(:kind)).to eq([ "branch" ])
  end
end
