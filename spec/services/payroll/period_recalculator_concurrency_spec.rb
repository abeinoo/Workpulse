require "rails_helper"

# Payroll::PeriodRecalculator under real concurrency, with database connections
# of their own. apply! locks the payroll period row first (as Payroll::Approver
# does), so:
#   - two confirmations of the same preview serialize: the second waits, then
#     finds the inputs changed and is refused — one run, one snapshot, one audit;
#   - a finalization started while a recalculation runs waits for it, then sees
#     the entries it flagged for re-review and is refused.
# A pass is not proof that a race is impossible.
#
# Harness (Queue handshake, no sleeps, bounded waits, empty-database guard and
# truncation) copied from spec/services/organization_access/branch_lifecycle_concurrency_spec.rb.
RSpec.describe "Payroll period recalculation under concurrency (two connections)" do
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

  # Pauses the FIRST recalculation's audit write (entries rewritten and flagged,
  # the transaction still open and the period lock held) until released.
  def pause_first_recalculation
    reached = Queue.new
    release = Queue.new
    calls   = 0
    allow_any_instance_of(Payroll::PeriodRecalculator).to receive(:write_audit!).and_wrap_original do |original, *args|
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

  let(:business) { create(:business, working_days_per_month: 26, timezone: "UTC") }
  let(:branch)   { create(:branch, business: business) }
  let(:actor)    { create(:user, :accountant, business: business) }
  let(:employee) { create(:user, business: business) }
  let(:shift)    { create(:shift, :fixed_time, business: business) }
  let(:period)   { create(:payroll_period, business: business, period_year: 2026, period_month: 10, working_days: 26) }

  before do
    assignment = create(:shift_assignment, user: employee, branch: branch, shift: shift, effective_from: Date.new(2026, 1, 1))
    [ 10, 20 ].each do |d|
      date = Date.new(2026, 10, d)
      create(:attendance_record, user: employee, branch: branch, shift_assignment: assignment, date: date, work_date: date,
             check_in_at: Time.zone.local(2026, 10, d, 9), check_out_at: Time.zone.local(2026, 10, d, 17),
             worked_minutes: 480, late_minutes: 0, early_leave_minutes: 0, status: "present")
    end
    create(:salary_profile, :daily, user: employee, base_amount: 400, effective_from: Date.new(2026, 1, 1))
    Payroll::EntryCalculator.call(period: period, user: employee, business: business)
    period.update!(status: "branch_review_completed")
    create(:salary_profile, :daily, user: employee, base_amount: 500, effective_from: Date.new(2026, 10, 15))
    @digest = Payroll::PeriodRecalculator.new(period_id: period.id, actor: actor).preview.preview.digest
  end

  def apply_on_other_connection
    on_other_connection do
      Payroll::PeriodRecalculator.new(period_id: period.id, actor: actor).apply!(expected_digest: @digest, reason: "fix")
    end
  end

  it "serializes two confirmations of the same preview: one run, the other refused" do
    reached, release = pause_first_recalculation
    first = apply_on_other_connection
    wait_for(reached)

    second = apply_on_other_connection
    wait_until_lock_waits("%payroll_periods%FOR UPDATE%")
    release << true

    results = [ result_of(first), result_of(second) ]
    expect(results.map(&:ok?)).to eq([ true, false ])
    expect(results.last.error).to eq(I18n.t("payroll.period_recalculation.errors.preview_changed"))
    expect(PayrollAuditLog.where(action_type: "recalculated").count).to eq(1)
    expect(PayrollSnapshot.where(trigger: "pre_recalculate").count).to eq(1)
    expect(PayrollEntry.find_by!(user: employee).base_salary).to eq(BigDecimal("900"))
  end

  it "makes a finalization started during a recalculation wait, then refuses it" do
    reached, release = pause_first_recalculation
    recalculation = apply_on_other_connection
    wait_for(reached)

    finalization = on_other_connection { Payroll::Approver.advance(period: PayrollPeriod.find(period.id), by: actor) }
    wait_until_lock_waits("%payroll_periods%FOR UPDATE%")
    release << true

    expect(result_of(recalculation)).to be_ok
    finalized = result_of(finalization)
    expect(finalized).not_to be_success
    expect(finalized.error).to eq(I18n.t("payroll.errors.recalculation_review_required_finalize", count: 1))
    expect(period.reload.status).to eq("branch_review_completed")
  end
end
