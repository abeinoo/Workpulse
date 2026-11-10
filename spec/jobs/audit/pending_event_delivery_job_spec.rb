require "rails_helper"

# R3.1 delivery job: a thin wrapper around Audit::PendingEventDelivery.
RSpec.describe Audit::PendingEventDeliveryJob do
  it "runs one delivery attempt for the event" do
    event = create(:pending_audit_event, attempted_at: 10.minutes.ago, next_attempt_at: 1.minute.ago)

    described_class.perform_now(event.id)

    expect(event.reload).to be_resolved
  end

  it "runs on the background queue, at most one job per event at a time (an optimisation only)" do
    job = described_class.new(42)

    expect(job.queue_name).to eq("background")
    expect(job.concurrency_key).to include("pending_audit_event/42")
    expect(described_class.concurrency_limit).to eq(1)
  end
end
