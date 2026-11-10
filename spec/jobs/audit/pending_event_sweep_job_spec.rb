require "rails_helper"
require "fugit" # Solid Queue's schedule parser

# R3.1 sweeper (§18.2 G10, T-R31-13): the durable record is the source of
# truth, so a lost enqueue only delays delivery; dispatch claims keep a queue
# backlog from piling up duplicate jobs.
RSpec.describe Audit::PendingEventSweepJob do
  include ActiveJob::TestHelper

  let(:now) { Time.zone.local(2026, 11, 8, 12, 0, 0) }

  it "enqueues a delivery for every due, unresolved event, and nothing else" do
    due     = create(:pending_audit_event, attempted_at: now - 10.minutes, next_attempt_at: now - 1.minute)
    _later  = create(:pending_audit_event, attempted_at: now, next_attempt_at: now + 1.minute)
    done    = create(:pending_audit_event, attempted_at: now - 10.minutes, next_attempt_at: now - 5.minutes)
    travel_to(now) { Audit::PendingEventDelivery.call(event_id: done.id) }

    travel_to(now) { described_class.perform_now }

    expect(enqueued_jobs.map { |job| job["arguments"] }).to eq([ [ due.id ] ])
    expect(Audit::PendingEventDeliveryJob).to have_been_enqueued.with(due.id).on_queue("background")
  end

  it "recovers a lost enqueue: the due event is delivered once, with its original attempt time" do
    business  = create(:business)
    actor     = create(:user, business: business)
    auditable = create(:user, business: business)
    fail_audit_writes!
    allow(Audit::PendingEventDeliveryJob).to receive(:set).and_raise(ActiveRecord::ConnectionNotEstablished, "queue down")

    result = travel_to(now) do
      Audit::DurableEntry.record(actor: actor, auditable: auditable, action: "daily_paid_attendance_rejected",
                                 metadata: { "reason" => "conflict" })
    end
    expect(result).to be_pending
    expect(enqueued_jobs).to be_empty

    RSpec::Mocks.space.proxy_for(AuditLog).reset
    RSpec::Mocks.space.proxy_for(Audit::PendingEventDeliveryJob).reset
    travel_to(now + 2.minutes) do
      described_class.perform_now
      perform_enqueued_jobs
    end

    expect(AuditLog.sole).to have_attributes(actor_id: actor.id, business_id: business.id, auditable_id: auditable.id,
                                             metadata: { "reason" => "conflict" }, created_at: now)
    expect(result.record.reload).to be_resolved
  end

  describe "dispatch claims (T-R31-13)" do
    def delivery_jobs = enqueued_jobs.select { |job| job["job_class"] == "Audit::PendingEventDeliveryJob" }

    let!(:due) { create(:pending_audit_event, attempted_at: now - 10.minutes, next_attempt_at: now - 1.minute) }

    it "enqueues one job for an event, however many sweeps run before a worker picks it up" do
      travel_to(now) { 2.times { described_class.perform_now } }
      travel_to(now + 5.minutes) { described_class.perform_now }

      expect(delivery_jobs.map { |job| job["arguments"] }).to eq([ [ due.id ] ])
      expect(due.reload.dispatch_claimed_until).to eq(now + PendingAuditEvent::DISPATCH_GRACE)
    end

    it "re-enqueues a lost job once its claim has lapsed" do
      travel_to(now) { described_class.perform_now }
      travel_to(now + PendingAuditEvent::DISPATCH_GRACE) { described_class.perform_now }

      expect(delivery_jobs.map { |job| job["arguments"] }).to eq([ [ due.id ], [ due.id ] ])
    end

    it "leaves an event alone while the job enqueued for its retry holds the claim" do
      due.update_columns(dispatch_claimed_until: now + 1.hour)

      travel_to(now) { described_class.perform_now }

      expect(delivery_jobs).to be_empty
    end

    it "keeps going when one enqueue fails, and releases that event's claim" do
      other = create(:pending_audit_event, attempted_at: now - 10.minutes, next_attempt_at: now - 30.seconds)
      allow(Audit::PendingEventDeliveryJob).to receive(:perform_later).and_wrap_original do |original, event_id|
        raise ActiveRecord::ConnectionNotEstablished, "queue down" if event_id == due.id

        original.call(event_id)
      end

      travel_to(now) { described_class.perform_now }

      expect(delivery_jobs.map { |job| job["arguments"] }).to eq([ [ other.id ] ])
      expect(due.reload.dispatch_claimed_until).to be_nil
      expect(other.reload.dispatch_claimed_until).to eq(now + PendingAuditEvent::DISPATCH_GRACE)
    end

    it "never enqueues a resolved event" do
      travel_to(now) { Audit::PendingEventDelivery.call(event_id: due.id) }
      clear_enqueued_jobs

      travel_to(now + 1.hour) { described_class.perform_now }

      expect(delivery_jobs).to be_empty
    end
  end

  it "is scheduled every five minutes on the background queue in production" do
    entry = YAML.load_file(Rails.root.join("config/recurring.yml")).dig("production", "sweep_pending_audit_events")

    expect(entry).to eq("class" => "Audit::PendingEventSweepJob", "queue" => "background", "schedule" => "every 5 minutes")
    expect(Fugit.parse(entry["schedule"])).to be_present
  end
end
