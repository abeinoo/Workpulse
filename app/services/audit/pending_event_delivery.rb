module Audit
  # One delivery attempt of a PendingAuditEvent (R3.1; plan §6.8, §18.2 G10,
  # §19.13). Called by Audit::PendingEventDeliveryJob.
  #
  # Exactly-once: the event row is locked FOR UPDATE NOWAIT (busy → this
  # attempt does nothing), re-checked after the lock (resolved → stop; not yet
  # due → stop, so a duplicate job never shortens the backoff). If the entry's
  # DurableAuditReceipt already exists (its first write committed although the
  # writer never got the confirmation), the event resolves to that AuditLog and
  # nothing is written. Otherwise the AuditLog insert, its receipt and the
  # event's resolution are one savepoint inside the locked transaction; the
  # receipt's unique entry_key makes a second AuditLog for the entry impossible
  # in the database (T-R31-11). The delivered entry keeps the original actor,
  # business, auditable, action, changes and metadata, and the original attempt
  # time as created_at (D29).
  #
  # A failed insert updates the event's counters and schedule in place
  # (escalation at the third consecutive failed retry, once) and commits. When
  # the delivery transaction fails as a whole (lost connection, serialization
  # failure, failed commit), it is rolled back and the failure is recorded in a
  # new, independent transaction — counters, schedule, escalation and the
  # attempt row together (T-R31-12, owner decision M1). If that transaction
  # fails too, nothing is recorded and the result says so; the event is
  # unchanged and still due, and the sweeper retries it.
  #
  # The attempt-log row of a completed delivery transaction is written
  # afterwards in its own transaction (T-R31-1): a failed attempt-log write never
  # turns a delivery into a failure. After a recorded failure the next retry is
  # enqueued at its exact time (T-R31-13); the sweeper only recovers lost jobs.
  #
  # AuditLoggable is included for its error classification and schema-only
  # error details; its log_audit / log_audit! are not used here.
  class PendingEventDelivery
    include AuditLoggable
    include Audit::SafeReporting

    # outcome: :delivered, :failed, :busy (another attempt holds the lock),
    # :already_resolved or :not_due. attempt_recorded: whether this attempt's
    # attempt-log row was written (false also when there was nothing to record).
    Result = Struct.new(:outcome, :audit_log, :error, :attempt_recorded, keyword_init: true) do
      def delivered? = outcome == :delivered
    end

    # Longest wait for the event's row lock when recording a failed delivery
    # transaction (T-R31-12).
    RECORDING_LOCK_TIMEOUT = "5s".freeze

    def self.call(event_id:) = new(event_id).call

    def initialize(event_id)
      @event_id         = event_id
      @attempt_recorded = false
    end

    def call
      started_at = Time.current
      outcome    = deliver(started_at)
      record_attempt(outcome, started_at) if @attempt_row_pending
      schedule_next_retry if @schedule_retry
      Result.new(outcome: outcome, audit_log: (@audit_log if outcome == :delivered), error: @error,
                 attempt_recorded: @attempt_recorded)
    end

    private

    def deliver(started_at)
      outcome = PendingAuditEvent.transaction do
        @event = PendingAuditEvent.lock("FOR UPDATE NOWAIT").find(@event_id)
        if @event.resolved?
          :already_resolved
        elsif !@event.due?
          :not_due
        else
          attempt!
        end
      end
      @attempt_row_pending = %i[delivered failed].include?(outcome)
      outcome
    rescue ActiveRecord::LockWaitTimeout
      :busy
    rescue ActiveRecord::RecordNotFound
      raise
    rescue StandardError => e
      # Nothing was attempted when the lock was never taken: the event is
      # untouched and the job fails visibly.
      raise unless @event

      record_transaction_failure(e, started_at)
    end

    def attempt!
      @attempt_at = Time.current.floor(6)
      if (receipt = DurableAuditReceipt.find_by(entry_key: @event.entry_key))
        @event.adopt_receipt!(receipt, at: @attempt_at)
        @audit_log = receipt.audit_log
      else
        AuditLog.transaction(requires_new: true) do
          @audit_log = AuditLog.create!(delivered_entry_attributes)
          @event.mark_delivered!(@audit_log, at: @attempt_at)
        end
      end
      @delivered_audit_log_id = @audit_log.id
      :delivered
    rescue StandardError => e
      raise if unrecoverable_audit_error?(e) || !audit_transaction_usable?

      @audit_log = @delivered_audit_log_id = nil
      @error = e
      @event.reload.record_failure!(error_class: e.class.name, error_details: error_identifiers(e).except(:error_class),
                                    at: @attempt_at)
      @next_attempt_at = @event.next_attempt_at
      @schedule_retry  = true
      report_failure(e, @event)
      :failed
    end

    def delivered_entry_attributes
      {
        actor_id:       @event.actor_id,
        business_id:    @event.business_id,
        auditable_type: @event.auditable_type,
        auditable_id:   @event.auditable_id,
        action:         @event.action,
        changes_json:   @event.payload.fetch("changes", {}),
        metadata:       @event.payload.fetch("metadata", {}),
        created_at:     @event.attempted_at
      }
    end

    # M1: the delivery transaction failed as a whole and was rolled back.
    # Record this attempt in an independent transaction — unless its effects
    # did commit (a commit whose confirmation was lost): then the event already
    # shows them, and only the attempt row is added. Exactly one attempt row.
    def record_transaction_failure(error, started_at)
      @error          = error
      @schedule_retry = false
      outcome = PendingAuditEvent.transaction(requires_new: true) do
        # Bounded wait: after a lost connection the old backend may still hold
        # the row lock until PostgreSQL notices; then this attempt stays
        # unrecorded and the sweeper retries the event later.
        PendingAuditEvent.connection.execute("SET LOCAL lock_timeout = '#{RECORDING_LOCK_TIMEOUT}'")
        event = PendingAuditEvent.lock.find(@event_id)
        result =
          if event.resolved? && @delivered_audit_log_id && event.audit_log_id == @delivered_audit_log_id
            @error = nil
            :delivered
          elsif event.resolved?
            :failed
          else
            committed_failure = @attempt_at && event.last_attempt_at == @attempt_at
            unless committed_failure
              event.record_failure!(error_class: error.class.name, error_details: error_identifiers(error).except(:error_class),
                                    at: @attempt_at || Time.current.floor(6))
            end
            @next_attempt_at = event.next_attempt_at
            @schedule_retry  = true
            :failed
          end
        create_attempt_row!(event, result, started_at)
        @report_event = event
        result
      end
      @audit_log = AuditLog.find_by(id: @delivered_audit_log_id) if outcome == :delivered
      report_failure(error, @report_event) if outcome == :failed
      outcome
    rescue StandardError => recording_error
      # Not recorded: the event is unchanged and still due; the sweeper retries
      # it once the database is available. Never claims a recorded attempt.
      @schedule_retry   = false
      @attempt_recorded = false
      log_safely("[AuditLog] Pending audit event #{@event_id}: delivery transaction failed (#{error.class}) " \
                 "and the failure could not be recorded (#{recording_error.class})")
      report_safely(error, severity: :error, context: { pending_audit_event_id: @event_id, attempt_recorded: false })
      :failed
    end

    def record_attempt(outcome, started_at)
      PendingAuditEventAttempt.transaction(requires_new: true) do
        create_attempt_row!(@event, outcome.to_s, started_at)
      end
    rescue StandardError => e
      @attempt_recorded = false
      log_safely("[AuditLog] Attempt log for pending audit event #{@event_id} not written (#{e.class})")
      report_safely(e, severity: :error, context: { pending_audit_event_id: @event_id, business_id: @event.business_id })
    end

    def create_attempt_row!(event, result, started_at)
      error = (@error if result.to_s == "failed")
      PendingAuditEventAttempt.create!(
        pending_audit_event_id: event.id, business_id: event.business_id, kind: "automatic",
        started_at: started_at, finished_at: [ Time.current, started_at ].max, result: result.to_s,
        error_class: error&.class&.name, error_details: error ? error_identifiers(error).except(:error_class) : {}
      )
      @attempt_recorded = true
    end

    # The next retry runs at its exact time; if the enqueue fails, the claim is
    # released so the sweeper enqueues it as soon as it is due.
    def schedule_next_retry
      Audit::PendingEventDeliveryJob.set(wait_until: @next_attempt_at).perform_later(@event_id)
    rescue StandardError => e
      begin
        PendingAuditEvent.unresolved.where(id: @event_id).update_all(dispatch_claimed_until: nil)
      rescue StandardError
        nil # the claim lapses on its own after DISPATCH_GRACE
      end
      log_safely("[AuditLog] Next retry of pending audit event #{@event_id} not enqueued (#{e.class}); the sweeper will")
      report_safely(e, severity: :warning, context: { pending_audit_event_id: @event_id })
    end

    # Ids, counters and schema identifiers only — never payload values, never
    # the database's message (T-R31-15).
    def report_failure(error, event)
      context = {
        pending_audit_event_id: event.id, business_id: event.business_id, action: event.action,
        attempts: event.attempts, consecutive_failures: event.consecutive_failures, escalated: event.escalated?
      }
      log_safely("[AuditLog] Pending audit event delivery failed #{context.merge(error_identifiers(error)).to_json}")
      report_safely(error, severity: event.escalated? ? :error : :warning, context: context)
    end
  end
end
