require "rails_helper"

# R3.1 delivery of a durable audit record (plan §6.8, §18.2 G10, §19.13, D29).
RSpec.describe Audit::PendingEventDelivery do
  include ActiveJob::TestHelper

  let(:business)     { create(:business) }
  let(:actor)        { create(:user, business: business) }
  let(:auditable)    { create(:user, business: business) }
  let(:attempted_at) { Time.zone.local(2026, 11, 8, 9, 0, 0) }
  let(:event) do
    create(:pending_audit_event, actor: actor, auditable_id: auditable.id, attempted_at: attempted_at,
                                 payload: { "changes" => { "base_salary" => [ "4000.0", "5500.0" ] },
                                            "metadata" => { "reason" => "SECRET-REASON" } })
  end

  let(:reports) { [] }
  let(:subscriber) do
    collected = reports
    Class.new { define_method(:report) { |error, **options| collected << options.merge(error: error) } }.new
  end

  around do |example|
    Rails.error.subscribe(subscriber)
    example.run
  ensure
    Rails.error.unsubscribe(subscriber)
  end

  def deliver(at:)
    travel_to(at) { described_class.call(event_id: event.id) }
  end

  def attempts = event.attempt_records.order(:id).pluck(:result)
  def own_reports = reports.select { |r| r[:source] == "pending_audit_event.work_pulse" }
  def retry_jobs = enqueued_jobs.select { |job| job["job_class"] == "Audit::PendingEventDeliveryJob" }

  it "writes exactly one AuditLog with the original actor, business, payload and attempt time, and its receipt" do
    result = deliver(at: attempted_at + 1.minute)

    expect(result.outcome).to eq(:delivered)
    expect(result.attempt_recorded).to be(true)
    expect(AuditLog.count).to eq(1)
    expect(result.audit_log.reload).to have_attributes(
      actor_id: actor.id, business_id: business.id, auditable_type: "User", auditable_id: auditable.id,
      action: event.action, changes_json: { "base_salary" => [ "4000.0", "5500.0" ] },
      metadata: { "reason" => "SECRET-REASON" }, created_at: attempted_at
    )
    expect(event.reload).to have_attributes(resolved_at: attempted_at + 1.minute, audit_log_id: result.audit_log.id,
                                            attempts: 1, consecutive_failures: 0, next_attempt_at: nil)
    expect(DurableAuditReceipt.sole).to have_attributes(entry_key: event.entry_key, audit_log_id: result.audit_log.id)
    expect(attempts).to eq(%w[delivered])
    expect(retry_jobs).to be_empty
  end

  it "keeps a failed attempt on the event, logs the attempt and enqueues the next retry at its exact time" do
    fail_audit_writes!
    result = deliver(at: attempted_at + 1.minute)

    expect(result.outcome).to eq(:failed)
    expect(AuditLog.count).to eq(0)
    expect(event.reload).to have_attributes(attempts: 1, consecutive_failures: 1, resolved_at: nil, escalated_at: nil,
                                            last_error: "ActiveRecord::InvalidForeignKey",
                                            next_attempt_at: attempted_at + 6.minutes)
    attempt = event.attempt_records.sole
    expect(attempt).to have_attributes(kind: "automatic", result: "failed", error_class: "ActiveRecord::InvalidForeignKey",
                                       business_id: business.id)
    expect(attempt.error_details).to include("sqlstate" => "23503")
    expect(Audit::PendingEventDeliveryJob).to have_been_enqueued.with(event.id).at(attempted_at + 6.minutes)
    expect(retry_jobs.size).to eq(1)
  end

  it "escalates exactly at the third consecutive failure, once, keeps retrying and keeps the history on delivery" do
    fail_audit_writes!
    times = [ 1.minute, 6.minutes, 21.minutes, 81.minutes ].map { |offset| attempted_at + offset }
    escalations = times.map do |at|
      expect(deliver(at: at).outcome).to eq(:failed)
      event.reload.escalated_at
    end

    expect(escalations).to eq([ nil, nil, times[2], times[2] ])
    expect(event.next_attempt_at).to eq(times[3] + 1.hour)
    expect(retry_jobs.map { |job| Time.zone.at(job["scheduled_at"].to_time) })
      .to eq([ times[0] + 5.minutes, times[1] + 15.minutes, times[2] + 1.hour, times[3] + 1.hour ])

    RSpec::Mocks.space.proxy_for(AuditLog).reset
    expect(deliver(at: times[3] + 1.hour).outcome).to eq(:delivered)
    expect(event.reload).to have_attributes(attempts: 5, consecutive_failures: 0, escalated_at: times[2], status: :resolved)
    expect(attempts).to eq(%w[failed failed failed failed delivered])
    expect(AuditLog.count).to eq(1)
  end

  it "does nothing before the event is due, so a duplicate job never shortens the backoff" do
    result = deliver(at: attempted_at + 30.seconds)

    expect(result.outcome).to eq(:not_due)
    expect(event.reload).to have_attributes(attempts: 0, resolved_at: nil)
    expect(AuditLog.count).to eq(0)
    expect(attempts).to be_empty
    expect(retry_jobs).to be_empty
  end

  it "never delivers a resolved event twice" do
    deliver(at: attempted_at + 1.minute)
    result = deliver(at: attempted_at + 2.hours)

    expect(result.outcome).to eq(:already_resolved)
    expect(AuditLog.count).to eq(1)
    expect(attempts).to eq(%w[delivered])
  end

  describe "idempotency (T-R31-11)" do
    it "resolves to the AuditLog already receipted under the entry key, writing no second one" do
      first_write = AuditLog.create!(actor_id: actor.id, business_id: business.id, auditable_type: "User",
                                     auditable_id: auditable.id, action: event.action)
      DurableAuditReceipt.create!(entry_key: event.entry_key, audit_log: first_write)

      result = deliver(at: attempted_at + 1.minute)

      expect(result.outcome).to eq(:delivered)
      expect(result.audit_log).to eq(first_write)
      expect(AuditLog.count).to eq(1)
      expect(event.reload).to have_attributes(audit_log_id: first_write.id, status: :resolved)
      expect(attempts).to eq(%w[delivered])
    end

    it "cannot write a second AuditLog even if the receipt check were skipped: the database refuses it" do
      first_write = AuditLog.create!(actor_id: actor.id, business_id: business.id, auditable_type: "User",
                                     auditable_id: auditable.id, action: event.action)
      DurableAuditReceipt.create!(entry_key: event.entry_key, audit_log: first_write)
      allow(DurableAuditReceipt).to receive(:find_by).and_return(nil)

      result = deliver(at: attempted_at + 1.minute)

      expect(result.outcome).to eq(:failed)
      expect(result.error).to be_a(ActiveRecord::RecordNotUnique)
      expect(AuditLog.count).to eq(1)
      expect(event.reload).to have_attributes(resolved_at: nil, attempts: 1)
    end
  end

  describe "a failure of the whole delivery transaction (owner decision M1)" do
    def fail_transaction_with(error_class)
      allow(AuditLog).to receive(:create!).and_raise(error_class, "lost")
    end

    it "rolls back, then counts the attempt, schedules the next retry and logs it in an independent transaction" do
      fail_transaction_with(ActiveRecord::ConnectionFailed)

      result = deliver(at: attempted_at + 1.minute)

      expect(result.outcome).to eq(:failed)
      expect(result.attempt_recorded).to be(true)
      expect(AuditLog.count).to eq(0)
      expect(DurableAuditReceipt.count).to eq(0)
      expect(event.reload).to have_attributes(attempts: 1, consecutive_failures: 1, resolved_at: nil,
                                              last_error: "ActiveRecord::ConnectionFailed",
                                              next_attempt_at: attempted_at + 6.minutes)
      expect(event.attempt_records.sole).to have_attributes(result: "failed", error_class: "ActiveRecord::ConnectionFailed")
      expect(Audit::PendingEventDeliveryJob).to have_been_enqueued.with(event.id).at(attempted_at + 6.minutes)
    end

    it "treats a serialization failure the same way" do
      fail_transaction_with(ActiveRecord::SerializationFailure)

      expect(deliver(at: attempted_at + 1.minute).outcome).to eq(:failed)
      expect(event.reload).to have_attributes(attempts: 1, last_error: "ActiveRecord::SerializationFailure")
      expect(attempts).to eq(%w[failed])
    end

    it "counts a deadlock once (it only aborts the savepoint)" do
      fail_transaction_with(ActiveRecord::Deadlocked)

      expect(deliver(at: attempted_at + 1.minute).outcome).to eq(:failed)
      expect(event.reload).to have_attributes(attempts: 1, consecutive_failures: 1, last_error: "ActiveRecord::Deadlocked")
      expect(attempts).to eq(%w[failed])
    end

    it "escalates at the third such failure, once, on the approved schedule" do
      fail_transaction_with(ActiveRecord::ConnectionFailed)
      times = [ 1.minute, 6.minutes, 21.minutes, 81.minutes ].map { |offset| attempted_at + offset }
      escalations = times.map do |at|
        deliver(at: at)
        event.reload.escalated_at
      end

      expect(escalations).to eq([ nil, nil, times[2], times[2] ])
      expect(event).to have_attributes(attempts: 4, consecutive_failures: 4, next_attempt_at: times[3] + 1.hour)
      expect(attempts).to eq(%w[failed failed failed failed])
    end

    it "records nothing — and says so — when the independent transaction fails too; the sweeper retries later" do
      fail_transaction_with(ActiveRecord::ConnectionFailed)
      allow(PendingAuditEventAttempt).to receive(:create!).and_raise(ActiveRecord::ConnectionNotEstablished, "still down")

      result = deliver(at: attempted_at + 1.minute)

      expect(result.outcome).to eq(:failed)
      expect(result.attempt_recorded).to be(false)
      expect(event.reload).to have_attributes(attempts: 0, consecutive_failures: 0, resolved_at: nil,
                                              next_attempt_at: attempted_at + 1.minute)
      expect(attempts).to be_empty
      expect(retry_jobs).to be_empty
      expect(own_reports.last[:context]).to include(pending_audit_event_id: event.id, attempt_recorded: false)

      RSpec::Mocks.space.proxy_for(AuditLog).reset
      RSpec::Mocks.space.proxy_for(PendingAuditEventAttempt).reset
      travel_to(attempted_at + 5.minutes) do
        Audit::PendingEventSweepJob.perform_now
        perform_enqueued_jobs(only: Audit::PendingEventDeliveryJob)
      end

      expect(event.reload).to be_resolved
      expect(AuditLog.count).to eq(1)
      expect(attempts).to eq(%w[delivered])
    end
  end

  it "keeps the delivery when only the attempt-log row fails (separate transaction, T-R31-1)" do
    allow(PendingAuditEventAttempt).to receive(:create!).and_raise(ActiveRecord::StatementInvalid, "attempt log down")

    result = deliver(at: attempted_at + 1.minute)

    expect(result.outcome).to eq(:delivered)
    expect(result.attempt_recorded).to be(false)
    expect(event.reload).to be_resolved
    expect(AuditLog.count).to eq(1)
    expect(own_reports).not_to be_empty
  end

  describe "error reporting (T-R31-15)" do
    it "reports ids, counters and schema identifiers, never payload values" do
      fail_audit_writes!
      deliver(at: attempted_at + 1.minute)

      report = own_reports.first
      expect(report[:context]).to include(pending_audit_event_id: event.id, business_id: business.id, attempts: 1,
                                          error_class: "ActiveRecord::InvalidForeignKey")
      expect(reports.map { |r| r[:context].to_s }.join).not_to include("SECRET-REASON", "5500")
    end

    it "never hands the database's message to the error reporter or the log" do
      leaking = ActiveRecord::StatementInvalid.new('PG::NotNullViolation: DETAIL: Failing row contains ({"reason": "SECRET-REASON"})')
      allow(AuditLog).to receive(:create!).and_raise(leaking)
      logged = []
      allow(Rails.logger).to receive(:error).and_wrap_original { |m, message| logged << message; m.call(message) }

      deliver(at: attempted_at + 1.minute)

      expect(own_reports).not_to be_empty
      own_reports.each do |report|
        expect(report[:error]).to be_a(Audit::SafeReporting::SanitizedError)
        expect(report[:error].message).to eq("ActiveRecord::StatementInvalid")
        expect(report[:context].to_s).not_to include("SECRET-REASON")
      end
      expect(logged.join).not_to include("SECRET-REASON")
      expect(event.reload.last_error).to eq("ActiveRecord::StatementInvalid")
      expect(event.attempt_records.sole.error_details.to_s).not_to include("SECRET-REASON")
    end
  end
end
