# Durable Audit Record — Operations (R3.1)

Operational guide for the durable audit record: `Audit::DurableEntry`, the
`pending_audit_events` / `pending_audit_event_attempts` / `durable_audit_receipts`
tables, the delivery job, the sweeper and the `/audit_failures` dashboard.
Design and decisions: `docs/architecture/attendance-requirements-and-cost-allocation-plan.md`
§19.13 (T-R31-1 … T-R31-15) and §2 V (D28–D34, with the D28 clarification).

**First release is dormant (D31).** No code path calls `Audit::DurableEntry` until
R3.4; until then the tables stay empty and the sweeper finds nothing. Existing
`log_audit` / `log_audit!` callers never write to these tables.

---

## 1. Deployment

1. **Migration** `20261108100000_create_pending_audit_events` creates the three
   tables, their constraints and the guard triggers. `bin/docker-entrypoint` runs
   `db:prepare` when the `web` container starts, so it is applied before the
   server boots. It only creates new tables (no existing data is touched); adding
   their foreign keys briefly takes a lock on `businesses`, `users` and
   `audit_logs`.
2. **Recurring sweeper** `sweep_pending_audit_events` (`config/recurring.yml`,
   production, `background` queue, every 5 minutes). Solid Queue runs inside Puma
   (`SOLID_QUEUE_IN_PUMA`), so restarting / recreating the `web` container restarts
   the supervisor, and its scheduler loads the new entry on start.
3. **Log rotation** (D34): `docker-compose.yml` sets bounded `json-file` rotation (see
   §4). It takes effect only when the containers are recreated:
   `docker compose up -d` (a plain `restart` keeps the old logging options).

**Verify** (`docker compose exec web ./bin/rails console`):

```ruby
ActiveRecord::Base.connection.select_values("SELECT tgname FROM pg_trigger WHERE NOT tgisinternal")
# => ["durable_audit_receipts_append_only", "pending_audit_event_attempts_append_only", "pending_audit_events_guard"]
SolidQueue::RecurringTask.find_by(key: "sweep_pending_audit_events")   # present, static: true
PendingAuditEvent.unresolved.count                                   # 0 while dormant
```

## 2. How retries run

- The original failed write is not a retry. Retries run 1, 5 and 15 minutes after
  each failure, then hourly; the event escalates at the third consecutive failed
  retry, once (badge on the sidebar, D32).
- Each retry is enqueued **at its exact time**: the first by `Audit::DurableEntry`,
  each later one by `Audit::PendingEventDelivery` after it has recorded the failure.
  Queue latency can delay a retry, never bring it forward (a job that runs early
  does nothing).
- The **sweeper only recovers lost jobs**. Every enqueued retry holds a dispatch
  claim (`dispatch_claimed_until` = retry time + 10 minutes); the sweeper enqueues
  only due events whose claim has lapsed, claimed atomically with
  `FOR UPDATE SKIP LOCKED`. A lost job is therefore re-enqueued at most ~15 minutes
  after its retry time (claim + sweep interval).
- A failure of the whole delivery transaction (lost connection, serialization
  failure) is recorded in a separate transaction and counts like any failure. If
  that cannot be committed either (or the event's row lock is not obtained within
  5 seconds), nothing is recorded — the event stays due and the sweeper retries it
  when the database is back. The event is never lost.

## 3. Rollback

The durable tables are the only copy of an entry that has not reached the Audit
Log yet. **Never roll back migration `20261108100000` once a producer (R3.4) has
written pending events** — the down migration drops them. While dormant, the
tables are empty and a schema rollback loses nothing.

Code rollback, in this order:

1. **Disable the sweeper**: remove `sweep_pending_audit_events` from
   `config/recurring.yml` in the build you are rolling back to, or deploy that
   build — it does not contain the entry.
2. **Restart the Solid Queue supervisor** (recreate the `web` container). Verified
   in Solid Queue 1.4.0 source (`SolidQueue::Scheduler::RecurringSchedule#persist_static_tasks`):
   on start the scheduler deletes every *static* recurring task that is no longer
   in the configuration (`RecurringTask.static.where.not(key: …).delete_all`), so
   the old schedule stops. Verify:

   ```ruby
   SolidQueue::RecurringTask.exists?(key: "sweep_pending_audit_events")   # => false
   ```

3. **Handle already-enqueued jobs** before removing the job classes, or they fail
   with `NameError` (harmless to the data, noisy in Mission Control). Delivery
   jobs can be scheduled up to an hour ahead (hourly retries). Either wait until
   none is left, or discard them. Discarding is safe: the events stay in
   `pending_audit_events` and are picked up again when the feature returns.

   **A delivery that is running while you discard can schedule another retry**
   when it fails (it enqueues its next retry after recording the failure), and
   once R3.4 exists a newly kept entry enqueues its first retry too. A single
   discard is therefore not enough: repeat the discard and the check until every
   count is 0. Only these two job classes are touched — never other application
   jobs.

   ```ruby
   audit_jobs  = -> { SolidQueue::Job.where(class_name: %w[Audit::PendingEventDeliveryJob Audit::PendingEventSweepJob],
                                            finished_at: nil) }
   discardable = [SolidQueue::ScheduledExecution, SolidQueue::BlockedExecution,
                  SolidQueue::ReadyExecution, SolidQueue::FailedExecution]

   # (a) Discard the waiting audit jobs. Each execution table discards its own
   #     jobs (Solid Queue 1.4.0).
   discardable.each { |executions| executions.discard_all_from_jobs(audit_jobs.call.to_a) }

   # (b) Check what is left: ready, scheduled, blocked and failed must all be 0.
   discardable.to_h { |executions| [executions.name.demodulize, executions.where(job_id: audit_jobs.call.select(:id)).count] }

   # (c) Running (claimed) jobs cannot be discarded (UndiscardableError) — let
   #     them finish; a delivery takes seconds.
   SolidQueue::ClaimedExecution.where(job_id: audit_jobs.call.select(:id)).count
   ```

   Repeat (a)–(c) until all five counts are 0. After a running job finishes,
   run (b) again: it may have scheduled another retry. The final check is
   `audit_jobs.call.count # => 0`.

4. **Revert the application code** only after step 3 shows no remaining jobs.
5. Pending events left in the table are retried automatically once R3.1 is
   redeployed (their next attempt is already due; the sweeper enqueues them).

## 4. Logs and the full-payload last resort (D28)

**What reaches the logs.** The durable path logs ids, counters, error class names
and schema identifiers only, and hands error reporters a sanitized error (class
name only, never the database message, which can quote row values). The single
exception is D28: when the durable record itself cannot be written, the full entry
— changes and metadata values included — is written to the **application log
only**, on one line starting with
`[AuditLog] Durable audit record could not be written; full entry for recovery`.
It carries `entry_key` (see *Manual recovery of a D28 entry* below). The full
entry is never sent to an error reporter.

**Manual recovery of a D28 entry.** R3.1 has **no recovery tool** — neither
automatic nor manual; operator tooling is planned with R3.5. A D28 line does
**not** prove the entry is missing: the first write or the pending event may
have committed although the application never received the confirmation. Before
any manual recovery, once the database is available again:

1. Take the `entry_key` from the D28 log line (and nothing else from it yet).
2. Check `durable_audit_receipts` for that key:
   `DurableAuditReceipt.find_by(entry_key: key)`. A receipt and its AuditLog are
   committed in the same transaction, so a receipt means the original AuditLog
   **was** committed (`receipt.audit_log_id`): the entry is recorded — **stop,
   recover nothing**.
3. Check `pending_audit_events` for that key:
   `PendingAuditEvent.find_by(entry_key: key)`. An event means the entry is
   durable: the delivery job or the sweeper writes it (or already has, if
   resolved) — **stop, recover nothing**; if it is escalated, fix the cause of
   the failures instead.
4. Only when **neither** exists was the entry written nowhere but the log. No
   receipt also means no AuditLog was committed for this entry (step 2).
5. The only safe recovery path is then an owner-approved, one-off write that
   inserts the AuditLog (original actor, business, auditable, action, changes and
   metadata from the log line, `created_at` = its `attempted_at`, D29) **and** a
   `durable_audit_receipts` row under the same `entry_key`, in one transaction —
   so the database's unique `entry_key` refuses it if the entry was written
   meanwhile. Record who ran it and when. Never write the AuditLog without the
   receipt, and never recover an entry whose key already has a receipt.

The privacy rules below are unchanged: the D28 line stays in the application
log; do not copy its values into tickets, chats or error reporters.

**Where the log lives.** Production logs go to STDOUT
(`config/environments/production.rb`), captured by Docker's `json-file` driver
on the host (`/var/lib/docker/containers/<id>/<id>-json.log`).

**Rotation (approved retention policy, D34, 2026-11-10).**
`docker-compose.yml` bounds every container's log with the `json-file` limits
`max-size: 20m` and `max-file: 5`: at most 100 MB of logs per container; the
oldest log file is removed when the limit is reached. The settings take effect
only once the containers are recreated (`docker compose up -d`, §1 step 3) — until
then a running container keeps its previous, unbounded logging options. D34
authorises no shipping of these logs to a third party.

**Who may read the logs.** Anyone with shell access to the host or the `docker`
group can read every container's log, D28 lines included. Restrict host / `docker`
group access to the operators who already hold production database access, since
the log can contain the same financial and personal values as the database.

**Error reporters.** The full payload is **never** sent automatically to Sentry
or any other external error reporter (D34). No `Rails.error` subscriber is configured today. Adding one
(Sentry, Honeybadger, …) requires an explicit privacy review of this path first:
the durable path sends only sanitized reports, but the unchanged global
`report_audit_failure` (BUG-003) passes the original exception, whose message can
quote row values.

**Database retention.** Pending events are never deleted (L34), so a resolved
event keeps its payload — a second copy of values that are also in its AuditLog —
indefinitely, protected by the guard triggers. This follows the approved
never-delete decision, and D34 confirms it: the full payload stored in the
database is not deleted automatically as part of R3.1, and no automatic database
retention or deletion job is authorised. Any change to it is an owner decision.

## 5. Database guards and the privilege boundary

**What the repository configures (verified):** `docker-compose.yml` creates the
database with `POSTGRES_USER: work_pulse`, and the `web` service connects with
`DATABASE_URL` as that same `work_pulse` role. The official `postgres` image
creates `POSTGRES_USER` as a **superuser**, and `bin/docker-entrypoint` runs
`db:prepare` as that role, so it also **owns** the tables it creates.

**Not confirmed on the production host:** the role's actual attributes there
(a host could have been set up differently). An operator can check read-only:
`SELECT rolsuper FROM pg_roles WHERE rolname = current_user;` in the production
console.

**What the guards protect against:** the triggers and constraints of §1 (never
deleted, append-only, identity and payload never change, a resolved event never
changes) stop application mistakes and ordinary SQL — `update_all`,
`delete_all`, raw `UPDATE` / `DELETE` — from any code path, whatever ActiveRecord
does.

**What they do not protect against:** a role with superuser privileges or
table ownership — the application role, as configured above — can remove or
bypass them: `ALTER TABLE … DISABLE TRIGGER`, `DROP TRIGGER`, `TRUNCATE` (row
triggers do not fire on it), or `session_replication_role = replica`. The
guards are **not** a protection against a compromised or misused superuser /
owner credential.

**Future improvement (outside R3.1):** a least-privilege application role — not
a superuser, not the table owner, without `TRUNCATE` on these tables — with
migrations run by a separate owner role. This is a separate security change;
R3.1 changes no roles, credentials, Docker users or production configuration.

## 6. Monitoring

- Business users with `monitor_audit_failures` (owners implicitly) see
  `/audit_failures`: status, failure class and schema details, attempts and times,
  escalation — never the payload (D30).
- `grep "\[AuditLog\]"` in the application log shows every durable-path event.
