require "rails_helper"

# F-A2 — two payments of the same salary advance, proven with TWO database
# connections (a second connection is the only thing a row lock can block).
# Requests::Approver#pay locks the request row (SELECT … FOR UPDATE, F-A1),
# re-checks it is payable and only then marks it paid, creates the Advance
# (Requests::AdvanceEffects → Payroll::AdvanceEffects) and writes the pay audit,
# all in one transaction; Requests::BulkPaymentService runs #pay for each request
# inside one outer transaction, so its locks are held until the batch commits.
# The unique index on advances.employee_request_id is the database backstop.
#
# Deterministic: the first payment is paused (blocking Queue handshake, no
# sleeps) right after its first Advance is created — the request row is locked
# and already paid, nothing committed; the second payment is then observed
# waiting on a lock while running the employee_requests FOR UPDATE
# (pg_stat_activity); every wait is bounded.
#
# Not transactional (the other connection must see committed rows): every
# example refuses to start unless the test database is empty and truncates every
# table afterwards — the harness of spec/services/attendance/punch_period_lock_spec.rb.
# Also covered: opposite-order bulk batches (F-A7 deadlock, ascending-id locking)
# and approve / reject / cancel racing on one request (F-A7 state transitions,
# "request state transitions" below).
RSpec.describe "Salary advance payment concurrency (two connections, F-A2)" do
  self.use_transactional_tests = false

  def self.data_tables(conn) = conn.tables - %w[schema_migrations ar_internal_metadata]

  # The guard: this example may truncate only a database it found empty.
  # @guard_passed is set only once the check succeeds; RSpec still runs `after`
  # when `before` raises, and then the database is left untouched.
  before do
    @guard_passed = false
    conn  = ActiveRecord::Base.connection
    dirty = self.class.data_tables(conn).select do |table|
      conn.select_value("SELECT EXISTS (SELECT 1 FROM #{conn.quote_table_name(table)})")
    end
    raise "test database not empty (#{dirty.first(5).join(', ')}…): refusing to run a truncating spec" if dirty.any?

    @guard_passed = true
  end

  # Cleanup: release every paused worker, then shut every worker down (bounded),
  # then truncate — but only when the guard passed AND no worker is alive AND
  # ConcurrencyConnectionCheck finds no other live connection or open session
  # (it waits briefly for the pool reaper; a leaked connection is reported but
  # does not block truncation, BUG-024). Otherwise truncation is skipped and the
  # hook fails loudly; it never pretends it cleaned.
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

  # Joins every worker; a worker's exception (re-raised by #join) is captured, never
  # allowed to skip the others. A worker still alive after the bounded join is
  # killed (its ensure blocks roll its transaction back and check its connection
  # in) and joined again; an unexpected escape still kills and joins the rest.
  # Returns [threads still alive, exceptions raised].
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

  let(:business)   { create(:business) }
  let(:accountant) { create(:user, :accountant, business: business) }
  let(:other_payer) { create(:user, :accountant, business: business) }

  def approved_advance(amount)
    create(:employee_request, :salary_advance, :approved, amount: amount, user: create(:user, business: business))
  end

  # Each operation loads its own copy (as a controller would) on its own connection.
  def pay(request_id, by: accountant) = Requests::Approver.pay(request: EmployeeRequest.find(request_id), paid_by: by)

  def bulk_pay(ids, by: accountant)
    Requests::BulkPaymentService.call(requests: ids.map { |id| EmployeeRequest.includes(:user, :advance).find(id) },
                                      paid_by: by, notes: "batch")
  end

  # Pauses the FIRST Advance creation (after it ran: the request row is locked,
  # marked paid and has its Advance, uncommitted) until released; later calls run
  # straight through.
  def pause_after_first_advance
    reached = Queue.new
    release = Queue.new
    calls   = 0
    allow(Payroll::AdvanceEffects).to receive(:advance_paid).and_wrap_original do |original, **kwargs|
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

  # Bounded wait until another backend is blocked on a lock while running the
  # request-row FOR UPDATE (Approver#pay's lock!). A deadline loop, not
  # Timeout.timeout around a query. Returns the waiting statement.
  def wait_until_request_lock_waits
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
    loop do
      query = ActiveRecord::Base.connection.select_value(<<~SQL)
        SELECT query FROM pg_stat_activity
        WHERE datname = current_database() AND pid <> pg_backend_pid()
          AND wait_event_type = 'Lock' AND query ILIKE '%employee_requests%FOR UPDATE%'
        LIMIT 1
      SQL
      return query if query
      raise "no backend waited for the request row lock within 10 s" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      Thread.pass
    end
  end

  def advances_of(request) = Advance.where(employee_request_id: request.id).count
  def pay_audits_of(request) = AuditLog.where(auditable_type: "EmployeeRequest", auditable_id: request.id, action: "pay").count
  def bulk_audits = AuditLog.where(action: "bulk_pay_advances")
  def status_of(request) = EmployeeRequest.find(request.id).status

  it "single vs single: the second payment waits for the row lock, then is refused — one Advance, one pay audit" do
    request = approved_advance(1_500.0)
    reached, release = pause_after_first_advance

    first = on_other_connection { pay(request.id) }
    wait_for(reached) # locked, paid and its Advance created — not committed

    second = on_other_connection { pay(request.id, by: other_payer) }
    expect(wait_until_request_lock_waits).to match(/FOR UPDATE/)
    expect(second.join(0)).to be_nil

    release << true
    expect(result_of(first)).to be_success

    refused = result_of(second)
    expect(refused).not_to be_success
    expect(refused.error).to eq(Requests::Approver::NOT_PAYABLE)

    expect(status_of(request)).to eq("paid")
    expect(advances_of(request)).to eq(1)
    expect(Advance.find_by!(employee_request_id: request.id).total_amount).to eq(1_500)
    expect(pay_audits_of(request)).to eq(1)
    expect(EmployeeRequest.find(request.id).reviewed_by_id).to eq(accountant.id)
  end

  it "bulk vs single: the single payment waits for the batch's lock, then is refused — the batch's payment stands" do
    request   = approved_advance(1_000.0)
    unrelated = approved_advance(700.0)
    reached, release = pause_after_first_advance

    batch = on_other_connection { bulk_pay([ request.id ]) }
    wait_for(reached)

    single = on_other_connection { pay(request.id, by: other_payer) }
    wait_until_request_lock_waits
    expect(single.join(0)).to be_nil

    release << true
    bulk = result_of(batch)
    expect(bulk.paid.map(&:id)).to eq([ request.id ])
    expect(bulk.skipped).to be_empty

    refused = result_of(single)
    expect(refused).not_to be_success
    expect(refused.error).to eq(Requests::Approver::NOT_PAYABLE)

    expect(status_of(request)).to eq("paid")
    expect(advances_of(request)).to eq(1)
    expect(pay_audits_of(request)).to eq(1)
    expect(bulk_audits.count).to eq(1)
    expect(bulk_audits.first.metadata).to include("request_ids" => [ request.id ], "request_count" => 1)

    expect(status_of(unrelated)).to eq("approved")
    expect(advances_of(unrelated)).to eq(0)
  end

  it "two batches with the same first lock: the second waits, skips the paid request and pays its own" do
    r1 = approved_advance(1_000.0)
    r2 = approved_advance(2_000.0)
    r3 = approved_advance(3_000.0)
    reached, release = pause_after_first_advance

    batch_a = on_other_connection { bulk_pay([ r1.id, r2.id ]) }
    wait_for(reached) # holds r1 (paid, Advance created), not committed

    batch_b = on_other_connection { bulk_pay([ r1.id, r3.id ], by: other_payer) }
    wait_until_request_lock_waits
    expect(batch_b.join(0)).to be_nil

    release << true
    a = result_of(batch_a)
    b = result_of(batch_b)

    expect(a.paid.map(&:id)).to eq([ r1.id, r2.id ])
    expect(a.skipped).to be_empty
    expect(b.paid.map(&:id)).to eq([ r3.id ])
    expect(b.skipped.map { |s| [ s.request.id, s.reason ] }).to eq([ [ r1.id, Requests::Approver::NOT_PAYABLE ] ])

    [ r1, r2, r3 ].each do |request|
      expect(status_of(request)).to eq("paid")
      expect(advances_of(request)).to eq(1)
      expect(pay_audits_of(request)).to eq(1)
    end
    expect(Advance.count).to eq(3)
    expect(EmployeeRequest.find(r1.id).reviewed_by_id).to eq(accountant.id) # batch A's payment, not overwritten

    expect(bulk_audits.count).to eq(2)
    expect(bulk_audits.map { |log| [ log.actor_id, log.metadata["request_ids"] ] })
      .to contain_exactly([ accountant.id, [ r1.id, r2.id ] ], [ other_payer.id, [ r3.id ] ])
  end

  # F-A7: from this (main) connection, may the row be locked right now? NOWAIT —
  # a row held by another transaction raises at once instead of waiting.
  def row_free?(request)
    EmployeeRequest.transaction { EmployeeRequest.lock("FOR UPDATE NOWAIT").find(request.id) }
    true
  rescue ActiveRecord::LockWaitTimeout
    false
  end

  it "opposite-order batches: ascending-id locking makes the second wait on r1 holding nothing — no deadlock (F-A7)" do
    r1 = approved_advance(1_000.0)
    r2 = approved_advance(2_000.0)
    r3 = approved_advance(3_000.0)
    reached, release = pause_after_first_advance

    batch_a = on_other_connection { bulk_pay([ r1.id, r2.id ]) }
    wait_for(reached) # holds r1 (paid, Advance created), not committed; r2 not locked yet

    batch_b = on_other_connection { bulk_pay([ r3.id, r2.id, r1.id ], by: other_payer) } # reversed selection
    wait_until_request_lock_waits
    expect(batch_b.join(0)).to be_nil

    # B waits on r1 without having locked r2 or r3 first (input order would lock r3, r2, then wait for r1).
    expect(row_free?(r1)).to be false
    expect(row_free?(r2)).to be true
    expect(row_free?(r3)).to be true

    release << true
    a = result_of(batch_a) # a deadlock would raise ActiveRecord::Deadlocked from one of these joins
    b = result_of(batch_b)

    expect(a.paid.map(&:id)).to eq([ r1.id, r2.id ])
    expect(b.paid.map(&:id)).to eq([ r3.id ])
    expect(b.skipped.map { |s| [ s.request.id, s.reason ] })
      .to eq([ [ r1.id, Requests::Approver::NOT_PAYABLE ], [ r2.id, Requests::Approver::NOT_PAYABLE ] ])

    [ r1, r2, r3 ].each do |request|
      expect(status_of(request)).to eq("paid")
      expect(advances_of(request)).to eq(1)
      expect(pay_audits_of(request)).to eq(1)
    end
    expect(Advance.count).to eq(3)
    expect(EmployeeRequest.where(id: [ r1.id, r2.id ]).pluck(:reviewed_by_id).uniq).to eq([ accountant.id ])

    expect(bulk_audits.map { |log| [ log.actor_id, log.metadata["request_ids"] ] })
      .to contain_exactly([ accountant.id, [ r1.id, r2.id ] ], [ other_payer.id, [ r3.id ] ])
  end

  # F-A7 — approve / reject / cancel of one request on two connections. Every
  # transition locks the request row first and re-checks the committed state, so
  # the second waits on the row lock (observed in pg_stat_activity) and is then
  # refused with the existing message instead of overwriting the first.
  describe "request state transitions" do
    let(:employee)   { create(:user, business: business) }
    let(:reviewer_a) { create(:user, :branch_manager, business: business) }
    let(:reviewer_b) { create(:user, :branch_manager, business: business) }

    # Pauses the FIRST audit write (the winner's: its status update is done and
    # its row lock held, nothing committed) until released.
    def pause_before_first_audit
      reached = Queue.new
      release = Queue.new
      calls   = 0
      allow(AuditLog).to receive(:create!).and_wrap_original do |original, *args, **kwargs, &block|
        calls += 1
        if calls == 1
          reached << true
          release.pop
        end
        original.call(*args, **kwargs, &block)
      end
      @releases = (@releases || []) << release
      [ reached, release ]
    end

    # Each operation loads its own copy on its own connection (as a controller does).
    def approve(id, by) = Requests::Approver.approve(request: EmployeeRequest.find(id), reviewed_by: by)
    def reject(id, by)  = Requests::Approver.reject(request: EmployeeRequest.find(id), reviewed_by: by)
    def cancel(id, by)  = Requests::Canceller.cancel(request: EmployeeRequest.find(id), cancelled_by: by, reason: "withdrawn")
    def actions_of(req) = AuditLog.where(auditable_type: "EmployeeRequest", auditable_id: req.id).order(:id).pluck(:action)

    # Runs `winner` until it is paused at its audit, starts `loser`, proves it
    # waits on the request row lock, releases the winner; returns both results.
    def race(winner, loser)
      reached, release = pause_before_first_audit
      first = on_other_connection { winner.call }
      wait_for(reached)

      second = on_other_connection { loser.call }
      wait_until_request_lock_waits
      expect(second.join(0)).to be_nil

      release << true
      [ result_of(first), result_of(second) ]
    end

    it "approve vs cancel (salary advance): the approval waits, then is refused — cancelled stands, no approval, no Advance" do
      req = create(:employee_request, :salary_advance, user: employee)

      cancelled, approval = race(-> { cancel(req.id, employee) }, -> { approve(req.id, reviewer_a) })

      expect(cancelled).to be_success
      expect(approval).not_to be_success
      expect(approval.error).to eq("Request is already cancelled")
      expect(EmployeeRequest.find(req.id)).to have_attributes(status: "cancelled", reviewed_by_id: nil, cancelled_by_id: employee.id)
      expect(actions_of(req)).to eq(%w[cancel])
      expect(Advance.where(employee_request_id: req.id)).to be_empty
    end

    it "approve vs approve: one succeeds, the other waits and is refused — one approval audit, the first reviewer" do
      req = create(:employee_request, :salary_advance, user: employee)

      first, second = race(-> { approve(req.id, reviewer_a) }, -> { approve(req.id, reviewer_b) })

      expect(first).to be_success
      expect(second.error).to eq("Request is already approved")
      expect(EmployeeRequest.find(req.id)).to have_attributes(status: "approved", reviewed_by_id: reviewer_a.id)
      expect(actions_of(req)).to eq(%w[approve])
    end

    {
      "approve wins over reject" => [ :approve, :reject, "approved" ],
      "reject wins over approve" => [ :reject, :approve, "rejected" ]
    }.each do |label, (winner, loser, final)|
      it "approve vs reject (#{label}): exactly one transition — final state and audits agree" do
        req = create(:employee_request, :salary_advance, user: employee)

        won, lost = race(-> { public_send(winner, req.id, reviewer_a) }, -> { public_send(loser, req.id, reviewer_b) })

        expect(won).to be_success
        expect(lost.error).to eq("Request is already #{final}")
        expect(EmployeeRequest.find(req.id)).to have_attributes(status: final, reviewed_by_id: reviewer_a.id)
        expect(actions_of(req)).to eq([ winner.to_s ])
      end
    end

    describe "a late permission with a real payroll effect" do
      let(:business)  { create(:business, working_days_per_month: 22) }
      let(:branch)    { create(:branch, business: business) }
      let(:shift)     { create(:shift, :fixed_time, business: business, start_time: Time.zone.parse("09:00"), end_time: Time.zone.parse("17:00")) }
      let(:work_date) { Date.new(2026, 6, 8) }
      let(:period)    { create(:payroll_period, business: business, period_year: 2026, period_month: 6, working_days: 22, status: "under_review") }
      let(:entry)     { create(:payroll_entry, payroll_period: period, user: employee, base_salary: 8_800, net_salary: 8_500, needs_review: false) }
      let!(:line) do # 40 min late → 25 % of the 400 daily rate
        assignment = create(:shift_assignment, user: employee, branch: branch, shift: shift, effective_from: Date.new(2026, 1, 1))
        create(:salary_profile, :monthly, user: employee, base_amount: 8_800.0, effective_from: Date.new(2026, 1, 1))
        create(:penalty_rule, shift: shift, rule_type: "late_arrival", threshold_minutes: 15,
                              deduction_type: "percentage_of_daily", deduction_value: 25)
        attendance = create(:attendance_record, user: employee, branch: branch, shift_assignment: assignment,
                                                date: work_date, work_date: work_date, late_minutes: 40, status: "late",
                                                check_in_at: Time.zone.local(2026, 6, 8, 9, 40))
        create(:payroll_line_item, payroll_entry: entry, item_type: "late_penalty", amount: -100.0, review_status: "approved",
                                   source_type: "AttendanceRecord", source_id: attendance.id,
                                   original_minutes: 40, permission_minutes: 0)
      end
      let!(:req) do
        build(:employee_request, :late_permission, user: employee, requested_for_date: work_date, duration_minutes: 20)
          .tap { |r| r.save!(validate: false) }
      end

      def line_now = PayrollLineItem.find(line.id)

      it "approval wins: the stale cancellation waits, is refused, and the applied effect stays with the approved request" do
        approval, cancelled = race(-> { approve(req.id, reviewer_a) }, -> { cancel(req.id, employee) })

        expect(approval).to be_success
        expect(cancelled.error).to eq(I18n.t("requests.errors.cannot_cancel"))
        expect(EmployeeRequest.find(req.id)).to have_attributes(status: "approved", cancelled_at: nil)
        expect(line_now.permission_minutes).to eq(20) # the effect of the approval that stands
        expect(actions_of(req)).to eq(%w[approve])
      end

      it "cancellation wins: the approval waits, is refused, and no effect is applied" do
        cancelled, approval = race(-> { cancel(req.id, employee) }, -> { approve(req.id, reviewer_a) })

        expect(cancelled).to be_success
        expect(approval.error).to eq("Request is already cancelled")
        expect(EmployeeRequest.find(req.id).status).to eq("cancelled")
        expect(line_now).to have_attributes(amount: -100.0, permission_minutes: 0) # untouched
        expect(actions_of(req)).to eq(%w[cancel])
      end
    end
  end
end
