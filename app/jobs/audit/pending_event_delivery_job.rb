module Audit
  # Delivers one PendingAuditEvent (R3.1). Enqueued at the retry's exact time
  # by Audit::DurableEntry (first retry, after the event is committed) and by
  # Audit::PendingEventDelivery (each later retry, after a recorded failure);
  # Audit::PendingEventSweepJob re-enqueues an event whose job was lost.
  # Exactly-once delivery comes from Audit::PendingEventDelivery's row lock and
  # the receipt's unique entry_key; limits_concurrency only avoids running two
  # jobs for the same event at once and is never relied on (§18.2 G10).
  class PendingEventDeliveryJob < ApplicationJob
    queue_as :background

    limits_concurrency to: 1, key: ->(event_id) { "pending_audit_event/#{event_id}" }, duration: 15.minutes

    def perform(event_id)
      Audit::PendingEventDelivery.call(event_id: event_id)
    end
  end
end
