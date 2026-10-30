require "rails_helper"

# BUG-026 — "a business always keeps one active branch" under real concurrency,
# with TWO database connections. Deactivation and deletion lock the business
# row first, so two requests retiring the last two active branches serialize:
# the second waits, then decides on the first's committed result. A pass is not
# proof that a race is impossible.
#
# Harness (Queue handshake, no sleeps, bounded waits, empty-database guard and
# truncation) copied from
# spec/characterization/inventory_purchasing/purchase_request_advance_concurrency_spec.rb.
RSpec.describe "Branch lifecycle — last active branch under concurrency (two connections, BUG-026)" do
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
  def on_other_connection(&block)
    Thread.new { ActiveRecord::Base.connection_pool.with_connection(&block) }
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

  # Pauses the FIRST audit write of `service_class` (the transition is written,
  # the transaction still open and the locks held) until released.
  def pause_first_audit_of(service_class)
    reached = Queue.new
    release = Queue.new
    calls   = 0
    allow_any_instance_of(service_class).to receive(:log_audit!).and_wrap_original do |original, **kwargs|
      calls += 1
      outcome = original.call(**kwargs)
      if calls == 1
        reached << true
        release.pop
      end
      outcome
    end
    @releases = (@releases || []) << release
    [ reached, release ]
  end

  let(:business) { create(:business) }
  let(:owner)    { create(:user, :owner, business: business) }
  let!(:first)   { create(:branch, business: business, name: "North", active: true) }
  let!(:second)  { create(:branch, business: business, name: "South", active: true) }

  def deactivate(branch) = OrganizationAccess::DeactivateBranch.new(branch.id, actor: owner, reason: "closing").call
  def delete_branch(branch) = OrganizationAccess::DeleteBranch.new(branch.id, actor: owner, reason: "mistake").call

  it "two deactivations of the last two active branches: the second waits, then is refused" do
    owner
    reached, release = pause_first_audit_of(OrganizationAccess::DeactivateBranch)
    winner = on_other_connection { deactivate(first) }
    wait_for(reached) # first branch deactivated, business + branch locked — not committed

    loser = on_other_connection { deactivate(second) }
    expect(wait_until_lock_waits("%businesses%FOR UPDATE%")).to match(/FOR UPDATE/)
    expect(loser.join(0)).to be_nil

    release << true
    expect(result_of(winner)).to be_ok
    expect(result_of(loser).error).to eq(:last_active_branch)

    expect(Branch.where(business_id: business.id, active: true).pluck(:id)).to eq([ second.id ])
    expect(AuditLog.where(auditable_type: "Branch", action: "deactivate").pluck(:auditable_id)).to eq([ first.id ])
  end

  it "a deactivation racing a deletion of the other active branch: the second waits, then is refused" do
    owner
    reached, release = pause_first_audit_of(OrganizationAccess::DeactivateBranch)
    deactivation = on_other_connection { deactivate(first) }
    wait_for(reached)

    deletion = on_other_connection { delete_branch(second) }
    expect(wait_until_lock_waits("%businesses%FOR UPDATE%")).to match(/FOR UPDATE/)

    release << true
    expect(result_of(deactivation)).to be_ok
    expect(result_of(deletion).error).to eq(:last_active_branch)
    expect(Branch.exists?(second.id)).to be(true)
    expect(Branch.find(second.id)).to be_active
  end

  # A new shift assignment and a deactivation of its branch serialize on the
  # branch row: the assignment's validation reads `active` under FOR SHARE,
  # held through its INSERT; the deactivation holds FOR UPDATE.
  describe "a shift assignment racing a deactivation of its branch" do
    let!(:shift)    { create(:shift, business: business) }
    let!(:employee) { create(:user, business: business) }

    def assign_at(branch)
      Shifts::Assigner.call(business: business,
                            params: { user_id: employee.id, shift_id: shift.id, branch_id: branch.id,
                                      effective_from: BusinessDay.current(context: business) })
    end

    def effective_assignments_at(branch)
      ShiftAssignment.where(branch_id: branch.id)
                     .where("effective_to IS NULL OR effective_to >= ?", BusinessDay.current(context: business))
    end

    # Pauses the FIRST ShiftAssignment save right after its validations — the
    # save's transaction open, the row not yet written — until released.
    def pause_first_assignment_after_validation
      reached = Queue.new
      release = Queue.new
      calls   = 0
      allow_any_instance_of(ShiftAssignment).to receive(:valid?).and_wrap_original do |original, *args|
        calls += 1
        outcome = original.call(*args)
        if calls == 1
          reached << true
          release.pop
        end
        outcome
      end
      @releases = (@releases || []) << release
      [ reached, release ]
    end

    it "deactivation first: the assignment waits on the branch, then is refused and nothing is written" do
      owner
      reached, release = pause_first_audit_of(OrganizationAccess::DeactivateBranch)
      deactivation = on_other_connection { deactivate(first) }
      wait_for(reached) # assignments checked, branch written inactive, business + branch locked — not committed

      assignment = on_other_connection { assign_at(first) }
      expect(wait_until_lock_waits("%branches%FOR SHARE%")).to match(/FOR SHARE/)
      expect(assignment.join(0)).to be_nil

      release << true
      expect(result_of(deactivation)).to be_ok
      outcome = result_of(assignment)
      expect(outcome).not_to be_success
      expect(outcome.error).to eq(I18n.t("activerecord.errors.models.shift_assignment.branch_inactive"))

      expect(Branch.find(first.id)).not_to be_active
      expect(ShiftAssignment.where(branch_id: first.id)).to be_empty
    end

    it "assignment first: the deactivation waits on the branch, then is refused and the branch stays active" do
      owner
      reached, release = pause_first_assignment_after_validation
      assignment = on_other_connection do
        ShiftAssignment.new(user: employee, shift: shift, branch: first,
                            effective_from: BusinessDay.current(context: business)).save
      end
      wait_for(reached) # branch read active under FOR SHARE, row not yet written — not committed

      deactivation = on_other_connection { deactivate(first) }
      expect(wait_until_lock_waits("%branches%FOR UPDATE%")).to match(/FOR UPDATE/)
      expect(deactivation.join(0)).to be_nil

      release << true
      expect(result_of(assignment)).to be(true)
      expect(result_of(deactivation).error).to eq(:active_assignments)

      expect(Branch.find(first.id)).to be_active
      expect(effective_assignments_at(first).count).to eq(1)
      expect(AuditLog.where(auditable_type: "Branch", action: "deactivate")).to be_empty
    end
  end
end
