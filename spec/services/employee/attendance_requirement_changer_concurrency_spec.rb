require "rails_helper"

# R3.2 G5 (attendance plan revision 19, OD-3, OD-11, OD-12, §19.14): the
# requirement change service under real concurrency — each operation on its
# own database connection and transaction; waits observed in pg_stat_activity;
# no lock call mocked (the only hooks pause an operation AFTER it took its
# locks). A pass is not proof that a race is impossible.
#
# Harness copied from spec/services/payroll/submit_for_review_concurrency_spec.rb.
RSpec.describe "Attendance requirement changes under concurrency (two connections)" do
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

  def wait_until_waiting(pattern)
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

  EMPLOYEE_LOCK = "%pg_advisory_xact_lock(#{Employee::AttendanceRequirements::LOCK_NAMESPACE},%".freeze
  SHARED        = "%pg_advisory_xact_lock_shared(%".freeze
  EXCLUSIVE     = "%pg_advisory_xact_lock(#{Payroll::StatusLock::NAMESPACE},%".freeze

  let(:business) do
    create(:business, timezone: "Africa/Cairo", business_day_start_hour: 6,
                      settings: { Workforce::AttendanceRequirementRollout::SETTING => "2026-01-01" })
  end
  let(:hr) do
    create(:user, business: business,
                  permission_role: create(:permission_role, business: business,
                                                            permissions: %w[view_employees manage_employees],
                                                            permission_scopes: { "view_employees" => "business",
                                                                                 "manage_employees" => "business" }))
  end
  let(:employee) { create(:user, business: business) }
  let(:colleague) { create(:user, business: business) }
  let!(:october) { create(:payroll_period, business: business, period_year: 2026, period_month: 10) }

  before do
    travel_to(Time.find_zone("Africa/Cairo").local(2026, 11, 15, 10, 0))
    [ employee, colleague ].each do |user|
      Employee::AttendanceRequirementChanger.call(user_id: user.id, status: "required", effective_from: Date.new(2026, 1, 1),
                                                  actor: hr, source: :creation)
    end
  end

  def change_on_other_connection(user: employee, status: "not_required", from: Date.new(2026, 10, 20), reason: "moved to remote")
    on_other_connection do
      Employee::AttendanceRequirementChanger.call(user_id: user.id, status: status, effective_from: from, reason: reason,
                                                  actor: hr, source: :hr_change)
    end
  end

  # Pauses the first history-row insert of the test (all locks held,
  # transaction open) until released.
  def pause_first_change
    reached = Queue.new
    release = Queue.new
    (@releases ||= []) << release
    calls = 0
    allow(EmployeeAttendanceRequirement).to receive(:create!).and_wrap_original do |original, *args, **kwargs|
      calls += 1
      row = original.call(*args, **kwargs)
      if calls == 1
        reached << true
        release.pop
      end
      row
    end
    [ reached, release ]
  end

  def pause_first_submission
    reached = Queue.new
    release = Queue.new
    (@releases ||= []) << release
    calls = 0
    allow(PayrollAuditLog).to receive(:create!).and_wrap_original do |original, *args, **kwargs|
      calls += 1
      record = original.call(*args, **kwargs)
      if calls == 1
        reached << true
        release.pop
      end
      record
    end
    [ reached, release ]
  end

  def wait_until_waiting(pattern)
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

  it "serialises two changes of the same employee: the second waits, then re-validates" do
    reached, release = pause_first_change
    first = change_on_other_connection(from: Date.new(2026, 12, 1), reason: nil)
    wait_for(reached)

    second = change_on_other_connection(from: Date.new(2026, 12, 1), reason: nil)
    wait_until_waiting(EMPLOYEE_LOCK)
    release << true

    expect(result_of(first)).to be_ok
    expect(result_of(second).error).to eq(:unchanged)
    expect(EmployeeAttendanceRequirement.where(user: employee).count).to eq(2)
  end

  it "lets different employees change at the same time, backdated changes included" do
    reached, release = pause_first_change
    first = change_on_other_connection(user: employee)
    wait_for(reached)

    expect(result_of(change_on_other_connection(user: colleague))).to be_ok # did not wait for the first
    release << true
    expect(result_of(first)).to be_ok
  end

  it "HR first: Submit for Review waits; the change (period Draft) commits; Submit then proceeds" do
    reached, release = pause_first_change
    change = change_on_other_connection
    wait_for(reached)

    submission = on_other_connection { Payroll::SubmitForReview.call(period: PayrollPeriod.find(october.id), by: hr) }
    wait_until_waiting(EXCLUSIVE)
    release << true

    expect(result_of(change)).to be_ok
    expect(result_of(submission)).to be_success
    expect(october.reload).to be_under_review
  end

  it "Submit first: the change waits, then sees the period under review and is refused, writing nothing" do
    reached, release = pause_first_submission
    submission = on_other_connection { Payroll::SubmitForReview.call(period: PayrollPeriod.find(october.id), by: hr) }
    wait_for(reached)

    change = change_on_other_connection
    wait_until_waiting(SHARED)
    release << true

    expect(result_of(submission)).to be_success
    refused = result_of(change)
    expect(refused.error).to eq(:payroll_protected)
    expect(refused.details).to include(starts_on: Date.new(2026, 10, 1), stage: :in_review)
    expect(EmployeeAttendanceRequirement.where(user: employee).count).to eq(1)
    expect(AuditLog.where(action: "attendance_requirement_changed", auditable: employee).count).to eq(1)
  end
end
