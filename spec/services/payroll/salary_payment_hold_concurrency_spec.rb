require "rails_helper"

# Salary Payment Hold under real concurrency, with database connections of their
# own (harness copied from spec/services/payroll/period_recalculator_concurrency_spec.rb):
#   - two HR users placing a hold on the same employee at once: one active hold
#     (the partial unique index decides), the other refused;
#   - a release started while Mark Paid is withholding: the new withholding row
#     key-share-locks its hold (foreign key), so the release waits for Mark Paid
#     to commit, then releases with that withholding on record — immediately
#     payable, never paid silently, never lost;
#   - two Pay Released Salary at once: one disbursement;
#   - a reopen holding the period lock while Pay Released waits: the payment
#     then finds the withholding voided and is refused.
# A pass is not proof that a race is impossible.
RSpec.describe "Salary Payment Hold under concurrency (two connections)" do
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

  # Pauses the first call of klass.method (inside the caller's open
  # transaction) until released.
  def pause_first_call(klass, method)
    reached = Queue.new
    release = Queue.new
    calls   = 0
    allow(klass).to receive(method).and_wrap_original do |original, *args, **kwargs, &block|
      calls += 1
      outcome = original.call(*args, **kwargs, &block)
      if calls == 1
        reached << true
        release.pop
      end
      outcome
    end
    @releases = (@releases || []) << release
    [ reached, release ]
  end

  let(:business)   { create(:business, timezone: "UTC") }
  let(:accountant) { create(:user, :accountant, business: business) }
  let(:hr) do
    role = business.permission_roles.create!(
      name: "HR", permissions: %w[view_payroll view_salary_payment_holds manage_salary_payment_holds],
      permission_scopes: { "view_payroll" => "business", "view_salary_payment_holds" => "business",
                           "manage_salary_payment_holds" => "business" }
    )
    create(:user, business: business, permission_role: role)
  end
  let(:employee) { create(:user, business: business) }
  let(:period) do
    create(:payroll_period, business: business, period_year: 2026, period_month: 10, status: :finalized).tap do |p|
      create(:payroll_entry, payroll_period: p, user: employee, net_salary: 5_000)
    end
  end

  def place(actor = hr)
    Payroll::SalaryHoldCreator.new(actor: actor, user_id: employee.id, reason: "pending_hr_review",
                                   effective_from: Date.new(2026, 10, 1)).call
  end

  it "two simultaneous holds on one employee: exactly one is placed" do
    other_hr = create(:user, business: business, permission_role: hr.permission_role)
    gate = Queue.new
    threads = [ hr, other_hr ].map { |actor| on_other_connection { gate.pop && place(actor) } }
    2.times { gate << true }
    results = threads.map { |t| result_of(t) }

    expect(results.count(&:ok?)).to eq(1)
    expect(results.reject(&:ok?).map(&:error)).to eq([ I18n.t("salary_payment_holds.errors.already_active") ])
    expect(SalaryPaymentHold.active.where(user: employee).count).to eq(1)
  end

  it "a release during Mark Paid waits for it, then leaves the withheld entry payable — never lost, never paid" do
    hold = place.record
    reached, release = pause_first_call(Payroll::SalaryWithholder, :withhold!)
    paying = on_other_connection { Payroll::Approver.advance(period: PayrollPeriod.find(period.id), by: accountant) }
    wait_for(reached)

    released = on_other_connection { Payroll::SalaryHoldReleaser.new(actor: hr, hold_id: hold.id).call }
    wait_until_lock_waits("%salary_payment_holds%")
    release << true
    expect(result_of(paying)).to be_success
    expect(result_of(released)).to be_ok
    expect(AuditLog.where(auditable_id: hold.id, action: "salary_hold_released").sole.metadata["outstanding_withholding_ids"])
      .to eq([ SalaryPaymentWithholding.sole.id ])

    withholding = SalaryPaymentWithholding.sole
    expect(withholding).to be_payable
    expect(withholding).not_to be_disbursed
    expect(period.reload).to be_paid
  end

  it "two simultaneous Pay Released Salary: one disbursement" do
    hold = place.record
    Payroll::Approver.advance(period: period, by: accountant)
    Payroll::SalaryHoldReleaser.new(actor: hr, hold_id: hold.id).call
    withholding = SalaryPaymentWithholding.sole

    gate = Queue.new
    threads = Array.new(2) do |i|
      on_other_connection do
        gate.pop
        Payroll::ReleasedSalaryPayer.new(actor: accountant, withholding_id: withholding.id, note: "pay #{i}").call
      end
    end
    2.times { gate << true }
    results = threads.map { |t| result_of(t) }

    expect(results.count(&:ok?)).to eq(1)
    expect(results.reject(&:ok?).map(&:error)).to eq([ I18n.t("salary_payment_holds.pay_released.errors.already_disbursed") ])
    expect(AuditLog.where(action: "released_salary_paid").count).to eq(1)
  end

  it "a reopen holding the period lock wins over a waiting Pay Released Salary, which is then refused" do
    hold = place.record
    Payroll::Approver.advance(period: period, by: accountant)
    Payroll::SalaryHoldReleaser.new(actor: hr, hold_id: hold.id).call
    withholding = SalaryPaymentWithholding.sole

    reached, release = pause_first_call(PayrollAuditLog, :create!)
    reopening = on_other_connection { Payroll::Reopener.call(period: PayrollPeriod.find(period.id), by: accountant, reason: "bank error") }
    wait_for(reached)

    paying = on_other_connection do
      Payroll::ReleasedSalaryPayer.new(actor: accountant, withholding_id: withholding.id, note: "late pay").call
    end
    wait_until_lock_waits("%payroll_periods%")
    release << true

    expect(result_of(reopening)).to be_success
    expect(result_of(paying).error).to eq(I18n.t("salary_payment_holds.pay_released.errors.voided"))
    expect(withholding.reload).to have_attributes(disbursed_at: nil, void_reason: "bank error")
  end
end
