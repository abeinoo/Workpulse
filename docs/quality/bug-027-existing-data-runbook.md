# BUG-027 — existing-data checks runbook (BUG-029, BUG-031..034)

The guards merged in PR #88 (BUG-029, `d792ffe`) and PR #90 (BUG-031..034, `87d13c2`) refuse new invalid writes. They
do not look at rows written **before** they were deployed. This runbook finds those rows. It is **read-only**: it
reports, it never repairs. Any correction is a separate, reviewed operation once the rows and their operational /
financial consequences are understood (see *After running*).

Queries: [`sql/bug-027-existing-data-checks.sql`](sql/bug-027-existing-data-checks.sql).

**Status:** prepared, not executed against production or a production replica. BUG-027 stays **Open** until this has
been run and its results triaged.

## When to run

- **After** the PR #88 / #90 guards are deployed — before that, the application can still write new rows of these
  kinds, so a clean result would not stay clean. Running once before deployment as well is harmless and gives a
  baseline.
- Any time later as a regression check (an empty result is expected once the guards are live).

## Safe execution

1. **Connection.** A read replica if one exists, otherwise a dedicated read-only role
   (`GRANT SELECT` only, `default_transaction_read_only = on`). **Never** the application's database credentials, and
   never a session that can write.
2. **Command:**

   ```sh
   psql "$READONLY_URL" -v ON_ERROR_STOP=1 -X -f docs/quality/sql/bug-027-existing-data-checks.sql > bug-027-results.txt
   ```

   - `-v ON_ERROR_STOP=1` stops at the first error instead of continuing.
   - `-X` ignores any local `.psqlrc`.
3. **What the file does:** opens `BEGIN TRANSACTION READ ONLY`, sets `statement_timeout = '30s'` and
   `lock_timeout = '2s'` for that transaction, runs **SELECT statements only**, then `ROLLBACK`. A write attempt
   inside the transaction is refused by PostgreSQL; on a replica every write is refused anyway.
4. **If a query times out:** do not raise the timeout on a primary. Run it on the replica, or narrow it with
   `AND <table>.business_id = <id>` and repeat per business.
5. **Output handling:** results contain record ids, business / branch ids, timestamps, a statement file name and a
   settlement amount — no personal data. Store them with the investigation, not in the repository.

## What each query checks

| Query | Bug | Relationship checked (the record's business vs. the referenced record's business) |
|---|---|---|
| Q1 | BUG-031 | `shift_template_entries.shift_id` → `shifts`, `shift_rule_profile_id` → `shift_rule_profiles`, against the entry's template (`shift_templates.business_id`) |
| Q2 | BUG-031 | `shift_assignments.user_id` → `users`, `shift_id` → `shifts`, `shift_rule_profile_id` → `shift_rule_profiles`, against the assignment's branch (`branches.business_id`) |
| Q3 | BUG-032 | `remaining_deposit_balance_transactions.payment_method_id` → `payment_methods`, against the balance (`remaining_deposit_balances.business_id`) |
| Q4 | BUG-033 | `bank_statements.branch_id` → `branches`, against `bank_statements.business_id` |
| Q5 | BUG-034 | `laundry_batches.towel_type_id` → `towel_types`, `operator_id` → `users`, against `laundry_batches.business_id` |
| Q6 | BUG-029 | towel transfers / adjustments, laundry batches and stock issues **created, dispatched (to), submitted or approved** at a currently inactive branch after its last recorded deactivation |

The queries were checked against the schema on `main` `3eefec6`. In a rolled-back test-database transaction, one
planted offending row per query was returned, and a document created before the deactivation was not (Q6).

## Reading the results

An empty result means no such row exists today. Every returned row is a reference **to investigate**, not proof of
harm:

- **Q1** — a saved template naming another business's shift / rule profile. Harmless until applied; Q2 shows the
  assignments it made (`source_template_id`).
- **Q2** — an assignment mixing businesses. Rows with `source_template_id` came through a template (the BUG-031 path);
  others came through another path and need tracing. **Follow-up F1** (in the SQL file, commented): attendance records
  matched to these assignments — their late / early-leave penalties, and the payroll entries built from them, used
  the foreign shift's times and penalty rules. Run F1 with the assignment ids from Q2.
- **Q3** — a settlement ledger row naming another business's payment method. Ledger rows are append-only; any
  correction is a compensating entry, never an edit.
- **Q4** — a statement for another business's branch; its matching ran against that branch's id (so it matched none
  of its own business's deposits). Soft-deleted statements are included — check `deleted_at`.
- **Q5** — a batch with a foreign towel type or operator. A batch with a foreign towel type could not have been
  started (the towel-ledger guard refused it), so no ledger entry is affected.
- **Q6** — `kind` says what happened after the deactivation. These are not cross-business rows; they are operations
  that BUG-029 now refuses. A `towel_transfer.dispatched_to_inactive` row means towels were sent to a closed branch.

## Follow-up queries needing earlier results

| Follow-up | Needs | Purpose |
|---|---|---|
| F1 (in the SQL file) | assignment ids from Q2 | attendance records (and so payroll penalties) computed with a foreign shift |
| Payroll impact (manual) | user ids and work dates from F1 | the payroll entries of those users / months, to see which totals included the affected penalties |
| Audit trail (manual) | any record id from Q1–Q6 | `SELECT * FROM audit_logs WHERE auditable_type = '<Model>' AND auditable_id = <id>` — who created it, when |

## What existing data cannot tell

- **Out-of-scope bank statements (BUG-033, same business).** Which branches an importer was entitled to at import time
  is not recorded, so a statement imported for a branch outside the importer's scope cannot be detected.
- **Inactive payment methods (BUG-032).** A same-business method that is inactive today cannot be told apart from one
  deactivated after the settlement, so only foreign methods are reported.
- **Branches deactivated before PR #87 (BUG-029, Q6).** Only deactivations made through
  `OrganizationAccess::DeactivateBranch` have an audit entry; a branch made inactive earlier (through the old edit
  form) has no deactivation time and is not checked. Its rows need a manual review against the branch's history.
- **Rows later corrected or deleted.** A cross-business reference that was edited away (or a deleted draft) leaves no
  trace in these tables; only `audit_logs` might show it.

## After running

1. Record the result per query (count, ids) in the BUG-027 entry of [`deferred-bugs.md`](deferred-bugs.md).
2. For each returned row, decide the correction with the business owner — a reviewed, separate change (data repair
   script or compensating entries), never an ad-hoc `UPDATE`.
3. BUG-027 can be closed only after the results are triaged and any corrections are complete.
