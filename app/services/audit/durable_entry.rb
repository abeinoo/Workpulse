module Audit
  # The opt-in durable audit write (R3.1; plan §6.6, §18.2 G10, §19.13
  # T-R31-8). For an entry that must never be lost silently — the first caller
  # is R3.4's rejected-attempt audit, written after its rolled-back transaction.
  #
  # The attempt time and the entry's idempotency key are fixed first, before
  # anything that can fail. Then log_audit! is called exactly once, in a
  # transaction that also writes the entry's DurableAuditReceipt (T-R31-11): if
  # that commit's confirmation is lost, the entry is kept pending under the same
  # key, and delivery finds the receipt instead of writing it twice.
  #
  # Three failure boundaries (T-R31-12):
  # 1. The write fails → the entry is kept in a PendingAuditEvent, in its own
  #    transaction. Only if THAT fails does the full entry go to the log as the
  #    last-resort recovery source (D28); the error report stays sanitized.
  # 2. The delivery enqueue fails after the event committed → the event is
  #    still durable (ok, pending); the sweeper enqueues it when due.
  # 3. Logging or reporting fails → swallowed; never reaches the caller.
  #
  # log_audit / log_audit! and their callers are unchanged (BUG-003): nothing
  # else writes a PendingAuditEvent or a receipt.
  #
  # Must be called outside any open transaction: a durable record written
  # inside a transaction that later rolls back would be lost with it.
  class DurableEntry
    include AuditLoggable
    include Audit::SafeReporting

    class CalledInsideTransaction < ArgumentError; end

    # record: the AuditLog when the entry was written, or the PendingAuditEvent
    # keeping it. Not ok only when the durable record could not be written
    # either (the entry is then in the log only).
    Result = Struct.new(:ok, :record, :error, keyword_init: true) do
      def ok?      = ok
      def pending? = record.is_a?(PendingAuditEvent)
    end

    def self.record(actor:, auditable:, action:, changes: {}, metadata: {})
      new.record(actor: actor, auditable: auditable, action: action, changes: changes, metadata: metadata)
    end

    def record(actor:, auditable:, action:, changes: {}, metadata: {})
      entry = { attempted_at: Time.current, entry_key: SecureRandom.uuid, actor: actor, auditable: auditable,
                action: action.to_s, changes: changes, metadata: metadata }
      ensure_outside_transaction!

      begin
        Result.new(ok: true, record: write_with_receipt(entry))
      rescue StandardError => error
        keep_pending(entry, error)
      end
    end

    private

    # Reads the thread's leased connection, if any, without checking one out:
    # no connection means no transaction, and the check itself cannot fail on
    # an unavailable database (T-R31-12).
    def ensure_outside_transaction!
      connection = ActiveRecord::Base.connection_pool.active_connection
      return unless connection&.current_transaction&.joinable?

      raise CalledInsideTransaction, "Audit::DurableEntry must be called outside any open transaction"
    end

    def write_with_receipt(entry)
      AuditLog.transaction do
        log_audit!(actor: entry[:actor], auditable: entry[:auditable], action: entry[:action],
                   changes: entry[:changes], metadata: entry[:metadata]).tap do |audit_log|
          DurableAuditReceipt.create!(entry_key: entry[:entry_key], audit_log: audit_log)
        end
      end
    end

    def keep_pending(entry, audit_error)
      event = begin
        persist_pending(entry, audit_error)
      rescue StandardError => write_error
        log_last_resort(entry, audit_error, write_error)
        return Result.new(ok: false, error: write_error)
      end

      note_kept_pending(event, audit_error)
      enqueue_delivery(event)
      Result.new(ok: true, record: event)
    end

    def persist_pending(entry, audit_error)
      root = root_error(audit_error)
      next_attempt_at = entry[:attempted_at] + PendingAuditEvent.retry_delay(1)
      PendingAuditEvent.transaction(requires_new: true) do
        PendingAuditEvent.create!(
          entry_key:              entry[:entry_key],
          business_id:            entry[:actor].business_id,
          actor_id:               entry[:actor].id,
          auditable_type:         entry[:auditable].class.polymorphic_name,
          auditable_id:           entry[:auditable].id,
          action:                 entry[:action],
          payload:                { "changes" => entry[:changes], "metadata" => entry[:metadata] },
          attempted_at:           entry[:attempted_at],
          next_attempt_at:        next_attempt_at,
          dispatch_claimed_until: next_attempt_at + PendingAuditEvent::DISPATCH_GRACE,
          last_error:             root.class.name,
          last_error_details:     error_identifiers(root).except(:error_class)
        )
      end
    end

    # log_audit! already reported an audit-write failure (unchanged global
    # report); any other cause (receipt write, lost commit confirmation) is
    # reported here, sanitized.
    def note_kept_pending(event, audit_error)
      log_safely("[AuditLog] Audit entry kept as pending audit event #{event.id} (#{root_error(audit_error).class})")
      return if audit_error.is_a?(AuditLoggable::AuditWriteFailed)

      report_safely(root_error(audit_error), severity: :warning,
                                             context: { pending_audit_event_id: event.id, business_id: event.business_id })
    end

    # The event is committed: an enqueue failure only delays it. Its dispatch
    # claim is released so the sweeper enqueues it as soon as it is due.
    def enqueue_delivery(event)
      Audit::PendingEventDeliveryJob.set(wait_until: event.next_attempt_at).perform_later(event.id)
    rescue StandardError => e
      begin
        PendingAuditEvent.unresolved.where(id: event.id).update_all(dispatch_claimed_until: nil)
      rescue StandardError
        nil # the claim lapses on its own after DISPATCH_GRACE
      end
      log_safely("[AuditLog] Pending audit event #{event.id} kept; enqueue failed (#{e.class}), the sweeper will deliver it")
      report_safely(e, severity: :warning, context: { pending_audit_event_id: event.id, business_id: event.business_id })
    end

    # D28: only here — the durable record itself could not be written — may the
    # full entry, values included, reach the log, as the last-resort recovery
    # source (entry_key keeps a manual recovery idempotent). Never the error
    # reporter: its context has keys and identifiers only.
    def log_last_resort(entry, audit_error, write_error)
      identifiers = {
        entry_key:                  entry[:entry_key],
        action:                     entry[:action],
        actor_id:                   entry[:actor].try(:id),
        business_id:                entry[:actor].try(:business_id),
        auditable_type:             entry[:auditable].class.try(:polymorphic_name),
        auditable_id:               entry[:auditable].try(:id),
        attempted_at:               entry[:attempted_at].iso8601(6),
        audit_error_class:          root_error(audit_error).class.name,
        durable_record_error_class: write_error.class.name
      }
      full_entry = identifiers.merge(changes: entry[:changes], metadata: entry[:metadata])
      begin
        log_safely("[AuditLog] Durable audit record could not be written; full entry for recovery #{full_entry.to_json}")
      rescue StandardError
        log_safely("[AuditLog] Durable audit record could not be written; entry not serializable #{identifiers.to_json}")
      end
      report_safely(write_error, severity: :error,
                                 context: identifiers.merge(change_keys: audit_keys(entry[:changes]),
                                                            metadata_keys: audit_keys(entry[:metadata])))
    end

    # log_audit! wraps the database error in AuditWriteFailed; keep the cause.
    def root_error(error)
      error.is_a?(AuditLoggable::AuditWriteFailed) && error.cause ? error.cause : error
    end
  end
end
