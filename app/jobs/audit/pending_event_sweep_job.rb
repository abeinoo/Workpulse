module Audit
  # Recurring sweeper (config/recurring.yml, every 5 minutes; R3.1, §18.2 G10,
  # §19.13 T-R31-13). Recovers deliveries whose job was lost: every retry is
  # already enqueued at its exact time by Audit::DurableEntry or
  # Audit::PendingEventDelivery, under a dispatch claim (dispatch_claimed_until).
  #
  # A sweep claims due, unresolved events whose claim has lapsed — atomically,
  # in one transaction with FOR UPDATE SKIP LOCKED, so two concurrent sweeps
  # never claim the same event and an event being delivered right now is
  # skipped — then enqueues one job per claimed event. While the claim holds,
  # later sweeps leave the event alone, so a queue backlog does not pile up
  # duplicates. One failed enqueue releases its claim and does not stop the
  # rest. A duplicate job is harmless anyway: the delivery re-checks the event
  # under its row lock.
  #
  # Deployment and rollback: docs/durable_audit_operations.md.
  class PendingEventSweepJob < ApplicationJob
    include Audit::SafeReporting
    include AuditLoggable

    queue_as :background

    BATCH_SIZE = 500

    def perform
      claim_due_events.each { |event_id| enqueue(event_id) }
    end

    private

    def claim_due_events
      now = Time.current
      PendingAuditEvent.transaction do
        ids = PendingAuditEvent.dispatchable(now).order(:next_attempt_at, :id).limit(BATCH_SIZE)
                               .lock("FOR UPDATE SKIP LOCKED").pluck(:id)
        PendingAuditEvent.where(id: ids).update_all(dispatch_claimed_until: now + PendingAuditEvent::DISPATCH_GRACE,
                                                    updated_at: now)
        ids
      end
    end

    def enqueue(event_id)
      Audit::PendingEventDeliveryJob.perform_later(event_id)
    rescue StandardError => e
      begin
        PendingAuditEvent.unresolved.where(id: event_id).update_all(dispatch_claimed_until: nil)
      rescue StandardError
        nil # the claim lapses on its own after DISPATCH_GRACE
      end
      log_safely("[AuditLog] Sweeper could not enqueue pending audit event #{event_id} (#{e.class})")
      report_safely(e, severity: :warning, context: { pending_audit_event_id: event_id })
    end
  end
end
