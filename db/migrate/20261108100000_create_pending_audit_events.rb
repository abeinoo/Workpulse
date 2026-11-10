# R3.1 — durable audit record (Infrastructure, Audit; plan §6.6, §6.8, §8, §18.2 G10, §19.13).
#
# durable_audit_receipts — one row per audit entry written through the opt-in
# R3.1 API, inserted in the same transaction as its AuditLog: entry_key (a UUID
# chosen before the first write) is unique, so no entry can ever be written
# twice — not by a retry after a commit whose confirmation was lost, nor by two
# deliveries (T-R31-11). audit_logs itself is unchanged.
#
# pending_audit_events — one row per audit entry whose write failed through the
# opt-in Audit::DurableEntry API (never through log_audit / log_audit!). The
# row is the entry's durable source until Audit::PendingEventDelivery writes the
# AuditLog, and it is the event's only notification (L34): counters and failure
# details are updated in place, resolution sets resolved_at + audit_log_id
# together, and the row is never deleted. payload holds the entry's changes and
# metadata (may contain financial or personal values) and is never shown on the
# business dashboard (D30). attempted_at is the original attempt time, used as
# the delivered entry's created_at (D29). A resolved event names the AuditLog
# receipted under its own entry_key (composite foreign key).
#
# pending_audit_event_attempts — append-only log of delivery attempts, in the
# business of its event (composite foreign key). R3.1 writes automatic attempts
# only; R3.5 adds the operator reference for manual attempts and widens the
# kind constraint (T-R31-4).
#
# The guard triggers enforce in the database what the models enforce in Ruby
# (T-R31-14): receipts and attempts are append-only; a pending event is never
# deleted, its identity and payload never change, a resolved event never
# changes, and escalation is set once. db/schema.rb carries the functions and
# triggers through config/initializers/schema_dumper_database_guards.rb.
class CreatePendingAuditEvents < ActiveRecord::Migration[8.1]
  def change
    create_table :durable_audit_receipts do |t|
      t.uuid       :entry_key, null: false, index: { unique: true }
      t.references :audit_log, null: false, foreign_key: true, index: { unique: true }
      t.datetime   :created_at, null: false
    end
    add_index :durable_audit_receipts, %i[entry_key audit_log_id], unique: true,
              name: "index_durable_audit_receipts_on_entry_key_and_audit_log"

    create_table :pending_audit_events do |t|
      t.uuid       :entry_key, null: false, index: { unique: true }
      t.references :business,  null: false, foreign_key: true
      t.references :actor,     null: false, foreign_key: { to_table: :users }
      t.string     :auditable_type, null: false
      t.bigint     :auditable_id,   null: false
      t.string     :action,         null: false
      t.jsonb      :payload,        null: false, default: {}
      t.datetime   :attempted_at,   null: false
      t.integer    :attempts,             null: false, default: 0
      t.integer    :consecutive_failures, null: false, default: 0
      t.string     :last_error
      t.jsonb      :last_error_details, null: false, default: {}
      t.datetime   :last_attempt_at
      t.datetime   :next_attempt_at
      t.datetime   :dispatch_claimed_until
      t.datetime   :escalated_at
      t.datetime   :resolved_at
      t.references :audit_log, foreign_key: true, index: { unique: true }
      t.timestamps
    end
    add_index :pending_audit_events, %i[id business_id], unique: true,
              name: "index_pending_audit_events_on_id_and_business"
    add_index :pending_audit_events, :next_attempt_at, where: "resolved_at IS NULL",
              name: "index_pending_audit_events_due"
    add_index :pending_audit_events, :business_id, where: "escalated_at IS NOT NULL AND resolved_at IS NULL",
              name: "index_pending_audit_events_escalated_unresolved"
    add_foreign_key :pending_audit_events, :durable_audit_receipts,
                    column: %i[entry_key audit_log_id], primary_key: %i[entry_key audit_log_id],
                    name: "fk_pending_audit_events_resolved_by_own_receipt"
    add_check_constraint :pending_audit_events, "(resolved_at IS NULL) = (audit_log_id IS NULL)",
                         name: "pending_audit_events_resolution_complete"
    add_check_constraint :pending_audit_events, "resolved_at IS NOT NULL OR next_attempt_at IS NOT NULL",
                         name: "pending_audit_events_unresolved_scheduled"
    add_check_constraint :pending_audit_events,
                         "attempts >= 0 AND consecutive_failures >= 0 AND consecutive_failures <= attempts",
                         name: "pending_audit_events_counters_valid"

    create_table :pending_audit_event_attempts do |t|
      t.references :pending_audit_event, null: false
      t.references :business,            null: false, foreign_key: true
      t.string     :kind,        null: false
      t.datetime   :started_at,  null: false
      t.datetime   :finished_at, null: false
      t.string     :result,      null: false
      t.string     :error_class
      t.jsonb      :error_details, null: false, default: {}
      t.datetime   :created_at,  null: false
    end
    add_foreign_key :pending_audit_event_attempts, :pending_audit_events,
                    column: %i[pending_audit_event_id business_id], primary_key: %i[id business_id],
                    name: "fk_pending_audit_event_attempts_same_business"
    add_check_constraint :pending_audit_event_attempts, "kind IN ('automatic')",
                         name: "pending_audit_event_attempts_kind_known"
    add_check_constraint :pending_audit_event_attempts, "result IN ('delivered', 'failed')",
                         name: "pending_audit_event_attempts_result_known"
    add_check_constraint :pending_audit_event_attempts, "finished_at >= started_at",
                         name: "pending_audit_event_attempts_times_ordered"

    reversible do |direction|
      direction.up   { execute GUARDS_UP }
      direction.down { execute GUARDS_DOWN }
    end
  end

  # Fixed messages, never row values (the error reaches logs and reports).
  GUARDS_UP = <<~SQL.freeze
    CREATE FUNCTION audit_append_only_guard() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      RAISE EXCEPTION '% is append-only', TG_TABLE_NAME USING ERRCODE = 'restrict_violation';
    END;
    $$;

    CREATE FUNCTION pending_audit_events_guard() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'pending_audit_events rows are never deleted' USING ERRCODE = 'restrict_violation';
      END IF;
      IF OLD.resolved_at IS NOT NULL THEN
        RAISE EXCEPTION 'a resolved pending audit event never changes' USING ERRCODE = 'restrict_violation';
      END IF;
      IF NEW.id IS DISTINCT FROM OLD.id OR NEW.entry_key IS DISTINCT FROM OLD.entry_key
         OR NEW.business_id IS DISTINCT FROM OLD.business_id OR NEW.actor_id IS DISTINCT FROM OLD.actor_id
         OR NEW.auditable_type IS DISTINCT FROM OLD.auditable_type OR NEW.auditable_id IS DISTINCT FROM OLD.auditable_id
         OR NEW.action IS DISTINCT FROM OLD.action OR NEW.payload IS DISTINCT FROM OLD.payload
         OR NEW.attempted_at IS DISTINCT FROM OLD.attempted_at OR NEW.created_at IS DISTINCT FROM OLD.created_at THEN
        RAISE EXCEPTION 'pending audit event identity and payload never change' USING ERRCODE = 'restrict_violation';
      END IF;
      IF NEW.attempts < OLD.attempts THEN
        RAISE EXCEPTION 'pending audit event attempts never decrease' USING ERRCODE = 'restrict_violation';
      END IF;
      IF OLD.escalated_at IS NOT NULL AND NEW.escalated_at IS DISTINCT FROM OLD.escalated_at THEN
        RAISE EXCEPTION 'pending audit event escalation is set once' USING ERRCODE = 'restrict_violation';
      END IF;
      RETURN NEW;
    END;
    $$;

    CREATE TRIGGER durable_audit_receipts_append_only BEFORE UPDATE OR DELETE ON durable_audit_receipts
      FOR EACH ROW EXECUTE FUNCTION audit_append_only_guard();
    CREATE TRIGGER pending_audit_event_attempts_append_only BEFORE UPDATE OR DELETE ON pending_audit_event_attempts
      FOR EACH ROW EXECUTE FUNCTION audit_append_only_guard();
    CREATE TRIGGER pending_audit_events_guard BEFORE UPDATE OR DELETE ON pending_audit_events
      FOR EACH ROW EXECUTE FUNCTION pending_audit_events_guard();
  SQL

  GUARDS_DOWN = <<~SQL.freeze
    DROP TRIGGER IF EXISTS pending_audit_events_guard ON pending_audit_events;
    DROP TRIGGER IF EXISTS pending_audit_event_attempts_append_only ON pending_audit_event_attempts;
    DROP TRIGGER IF EXISTS durable_audit_receipts_append_only ON durable_audit_receipts;
    DROP FUNCTION IF EXISTS pending_audit_events_guard();
    DROP FUNCTION IF EXISTS audit_append_only_guard();
  SQL
end
