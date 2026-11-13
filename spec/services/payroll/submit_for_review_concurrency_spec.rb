require "rails_helper"

# R3.2 G4 (attendance plan revision 19, OD-12, §19.14): Payroll::SubmitForReview
# and the D4 check of a backdated attendance-requirement change
# (Payroll::RequirementDateProtection, which the change service calls inside
# its transaction) under real concurrency, each on its own database
# connection and transaction. Waits are observed in pg_stat_activity; no lock
# call is mocked — the only hooks pause an operation AFTER it took its locks.
# A pass is not proof that a race is impossible.
#
# Harness (Queue handshake, bounded waits, empty-database guard, truncation)
# copied from spec/services/payroll/period_recalculator_concurrency_spec.rb.
RSpec.describe "Submit for Review and the D4 check under concurrency (two connections)" do
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

  SHARED    = "%pg_advisory_xact_lock_shared(%".freeze
  EXCLUSIVE = "%pg_advisory_xact_lock(%".freeze

  let(:business)       { create(:business) }
  let(:other_business) { create(:business) }
  let(:actor)          { create(:user, business: business) }
  let!(:october)       { create(:payroll_period, business: business, period_year: 2026, period_month: 10) }

  def submit_on_other_connection(period_id, by: actor)
    on_other_connection { Payroll::SubmitForReview.call(period: PayrollPeriod.find(period_id), by: by) }
  end

  # A backdated requirement change's D4 step, as the change service runs it:
  # inside its transaction, holding the locks until it commits — paused after
  # the check until released. `fail_after: true` rolls it back instead.
  def requirement_check_on_other_connection(business_id: business.id, from: Date.new(2026, 10, 5),
                                            through: Date.new(2026, 11, 20), fail_after: false)
    reached = Queue.new
    release = Queue.new
    (@releases ||= []) << release
    thread = on_other_connection do
      answer = nil
      ActiveRecord::Base.transaction do
        answer = Employee::PayrollDateProtection.lock_protected_range(business_id: business_id, from: from, through: through)
        reached << answer
        release.pop
        raise ActiveRecord::Rollback if fail_after
      end
      { answer: answer } # never nil, so the harness can tell "finished" from "stuck"
    end
    [ thread, reached, release ]
  end

  # Pauses the first submission after it wrote under_review and its audit
  # (locks held, transaction open) until released; `fail_after: true` then
  # makes it fail, rolling everything back.
  def pause_first_submission(fail_after: false)
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
        raise ActiveRecord::StatementInvalid, "forced failure" if fail_after
      end
      record
    end
    [ reached, release ]
  end

  it "HR first: Submit for Review waits; HR sees Draft and commits; Submit then proceeds" do
    hr, checked, release = requirement_check_on_other_connection
    expect(wait_for(checked)).to be_nil # October is Draft

    submission = submit_on_other_connection(october.id)
    wait_until_waiting(EXCLUSIVE)
    expect(october.reload).to be_draft
    release << true

    expect(result_of(hr)[:answer]).to be_nil
    expect(result_of(submission)).to be_success
    expect(october.reload).to be_under_review
  end

  it "Submit first: HR waits; after the submission commits HR sees Under Review and is refused" do
    reached, release = pause_first_submission
    submission = submit_on_other_connection(october.id)
    wait_for(reached)

    hr, checked, hr_release = requirement_check_on_other_connection
    wait_until_waiting(SHARED)
    release << true
    expect(result_of(submission)).to be_success

    answer = wait_for(checked)
    hr_release << true
    expect(answer).to have_attributes(starts_on: Date.new(2026, 10, 1), stage: :in_review)
    expect(result_of(hr)[:answer]).to have_attributes(stage: :in_review)
  end

  it "negative control: a status-filtered check without the payroll-status lock misses that race" do
    reached, release = pause_first_submission
    submission = submit_on_other_connection(october.id)
    wait_for(reached)

    naive = on_other_connection do
      ActiveRecord::Base.transaction do
        PayrollPeriod.where(business_id: business.id, status: %w[under_review branch_review_completed finalized paid])
                     .lock("FOR SHARE").to_a
      end
    end
    expect(result_of(naive)).to eq([]) # returned at once, before the submission committed
    release << true
    expect(result_of(submission)).to be_success
    expect(october.reload).to be_under_review
  end

  it "a month with no period row: generating it does not wait, submitting it waits until HR commits" do
    hr, checked, release = requirement_check_on_other_connection(from: Date.new(2026, 11, 1), through: Date.new(2026, 11, 30))
    expect(wait_for(checked)).to be_nil

    november = result_of(on_other_connection do
      PayrollPeriod.create!(business: business, period_year: 2026, period_month: 11, working_days: 26, status: :draft)
    end)
    submission = submit_on_other_connection(november.id)
    wait_until_waiting(EXCLUSIVE)
    expect(november.reload).to be_draft
    release << true

    expect(result_of(hr)[:answer]).to be_nil
    expect(result_of(submission)).to be_success
    expect(november.reload).to be_under_review
  end

  it "Submit rolls back: HR then proceeds on the Draft period" do
    reached, release = pause_first_submission(fail_after: true)
    submission = submit_on_other_connection(october.id)
    wait_for(reached)

    hr, checked, hr_release = requirement_check_on_other_connection
    wait_until_waiting(SHARED)
    release << true
    expect(result_of(submission)).not_to be_success

    expect(wait_for(checked)).to be_nil
    hr_release << true
    result_of(hr)
    expect(october.reload).to be_draft
  end

  it "HR rolls back: Submit for Review proceeds" do
    hr, checked, release = requirement_check_on_other_connection(fail_after: true)
    wait_for(checked)
    submission = submit_on_other_connection(october.id)
    wait_until_waiting(EXCLUSIVE)
    release << true

    result_of(hr)
    expect(result_of(submission)).to be_success
    expect(october.reload).to be_under_review
  end

  it "releases every lock at the end of each transaction" do
    hr, _checked, release = requirement_check_on_other_connection
    release << true
    result_of(hr)
    expect(result_of(submit_on_other_connection(october.id))).to be_success

    free = result_of(on_other_connection do
      ActiveRecord::Base.transaction do
        status_lock = ActiveRecord::Base.connection.select_value(
          "SELECT pg_try_advisory_xact_lock(#{Payroll::StatusLock::NAMESPACE}, #{business.id})"
        )
        row = PayrollPeriod.where(id: october.id).lock("FOR UPDATE NOWAIT").to_a
        [ status_lock, row.size ]
      end
    end)
    expect(free).to eq([ true, 1 ])
  end

  it "another business is never held up" do
    other_period = create(:payroll_period, business: other_business, period_year: 2026, period_month: 10)
    other_actor  = create(:user, business: other_business)
    hr, checked, release = requirement_check_on_other_connection
    wait_for(checked)

    expect(result_of(submit_on_other_connection(other_period.id, by: other_actor))).to be_success
    release << true
    result_of(hr)
  end

  it "two requirement checks of one business (different employees) never wait for each other" do
    first,  first_checked,  first_release  = requirement_check_on_other_connection
    second, second_checked, second_release = requirement_check_on_other_connection
    expect(wait_for(first_checked)).to be_nil
    expect(wait_for(second_checked)).to be_nil # both hold the shared locks at once
    first_release << true
    second_release << true
    result_of(first)
    result_of(second)
  end

  it "two submissions of one Draft period: one succeeds, the other waits and is refused" do
    reached, release = pause_first_submission
    first = submit_on_other_connection(october.id)
    wait_for(reached)

    second = submit_on_other_connection(october.id)
    wait_until_waiting(EXCLUSIVE)
    release << true

    expect(result_of(first)).to be_success
    refused = result_of(second)
    expect(refused).not_to be_success
    expect(refused.error).to eq(Payroll::SubmitForReview::REFUSAL)
    expect(PayrollAuditLog.where(payroll_period_id: october.id, action_type: "submitted_for_review").count).to eq(1)
  end
end
