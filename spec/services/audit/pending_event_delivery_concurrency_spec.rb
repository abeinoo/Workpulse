require "rails_helper"

# R3.1 exactly-once delivery (§18.2 G10), proven with TWO database connections
# (a second connection is the only thing a row lock can stop). The first
# delivery is paused (blocking Queue handshake, no sleeps) inside its locked
# transaction, just before its AuditLog insert; a second delivery of the same
# event is then started on another connection. Safe outcome: the second
# attempt is refused at once as busy (FOR UPDATE NOWAIT) and writes nothing;
# the first delivers; one AuditLog, one attempt-log row; a later attempt sees
# the event resolved.
#
# Not transactional (the other connection must see committed rows): the
# harness of spec/services/inventory/document_voider_concurrency_spec.rb —
# refuses to start unless the test database is empty, truncates afterwards,
# and checks worker connections with ConcurrencyConnectionCheck (BUG-024).
RSpec.describe "Audit::PendingEventDelivery concurrency (two connections)" do
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

  # Pauses the first AuditLog insert — inside the delivery's locked
  # transaction — until released.
  def pause_first_delivery
    reached = Queue.new
    release = Queue.new
    calls   = 0
    allow(AuditLog).to receive(:create!).and_wrap_original do |original, *args, **kwargs|
      calls += 1
      if calls == 1
        reached << true
        release.pop
      end
      original.call(*args, **kwargs)
    end
    @releases = (@releases || []) << release
    [ reached, release ]
  end

  let(:business) { create(:business) }
  let(:actor)    { create(:user, business: business) }
  let!(:event) do
    create(:pending_audit_event, actor: actor, attempted_at: 10.minutes.ago, next_attempt_at: 9.minutes.ago)
  end

  def deliver = Audit::PendingEventDelivery.call(event_id: event.id)

  it "delivers once: a second attempt while the first holds the lock is refused as busy and writes nothing" do
    reached, release = pause_first_delivery

    first = on_other_connection { deliver }
    wait_for(reached)

    second = on_other_connection { deliver }
    expect(result_of(second).outcome).to eq(:busy)

    release << true
    expect(result_of(first).outcome).to eq(:delivered)

    expect(AuditLog.count).to eq(1)
    expect(event.reload).to be_resolved
    expect(event.audit_log_id).to eq(AuditLog.sole.id)
    expect(PendingAuditEventAttempt.pluck(:result)).to eq(%w[delivered])

    expect(deliver.outcome).to eq(:already_resolved)
    expect(AuditLog.count).to eq(1)
    expect(DurableAuditReceipt.count).to eq(1)
  end

  it "gives up recording a failed delivery transaction after a bounded wait while another backend holds the lock" do
    locked  = Queue.new
    release = Queue.new
    (@releases ||= []) << release
    holder = on_other_connection do
      PendingAuditEvent.transaction do
        PendingAuditEvent.lock.find(event.id)
        locked << true
        release.pop
      end
    end
    wait_for(locked)

    delivery = Audit::PendingEventDelivery.new(event.id)
    delivery.instance_variable_set(:@event, PendingAuditEvent.find(event.id))
    started  = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    outcome  = delivery.send(:record_transaction_failure, ActiveRecord::ConnectionFailed.new("lost"), Time.current)
    waited   = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    expect(outcome).to eq(:failed)
    expect(delivery.instance_variable_get(:@attempt_recorded)).to be(false)
    expect(waited).to be_between(4, 9)
    release << true
    result_of(holder)
    expect(event.reload).to have_attributes(attempts: 0, consecutive_failures: 0)
    expect(PendingAuditEventAttempt.count).to eq(0)
  end

  describe "the sweeper (T-R31-13)" do
    include ActiveJob::TestHelper

    def delivery_job_ids = enqueued_jobs.select { |j| j["job_class"] == "Audit::PendingEventDeliveryJob" }.map { |j| j["arguments"].first }
    def sweep = Audit::PendingEventSweepJob.perform_now

    it "skips the event a delivery is working on (FOR UPDATE SKIP LOCKED)" do
      reached, release = pause_first_delivery

      first = on_other_connection { deliver }
      wait_for(reached)

      sweeper = on_other_connection { sweep }
      result_of(sweeper)
      expect(delivery_job_ids).to be_empty

      release << true
      expect(result_of(first).outcome).to eq(:delivered)
    end

    it "never lets two concurrent sweeps claim the same event" do
      second_event = create(:pending_audit_event, actor: actor, attempted_at: 10.minutes.ago, next_attempt_at: 8.minutes.ago)
      reached = Queue.new
      release = Queue.new
      (@releases ||= []) << release
      paused  = false
      allow(PendingAuditEvent).to receive(:where).and_wrap_original do |original, *args, **kwargs, &block|
        relation = original.call(*args, **kwargs, &block)
        if !paused && kwargs[:id].is_a?(Array) && kwargs[:id].any?
          paused = true
          reached << true
          release.pop
        end
        relation
      end

      first = on_other_connection { sweep }
      wait_for(reached)

      second = on_other_connection { sweep }
      result_of(second)
      expect(delivery_job_ids).to be_empty

      release << true
      result_of(first)
      expect(delivery_job_ids).to contain_exactly(event.id, second_event.id)
    end
  end
end
