-- BUG-027 existing-data checks (BUG-029, BUG-031..034). READ ONLY.
--
-- Run ONLY as described in docs/quality/bug-027-existing-data-runbook.md:
-- a read replica or a read-only role (never the application's credentials),
--   psql "$READONLY_URL" -v ON_ERROR_STOP=1 -X -f docs/quality/sql/bug-027-existing-data-checks.sql
-- Every statement is a SELECT inside a READ ONLY transaction that is rolled
-- back. Nothing here repairs, updates or deletes data.

BEGIN TRANSACTION READ ONLY;
SET LOCAL statement_timeout = '30s';
SET LOCAL lock_timeout = '2s';

-- Q1  BUG-031 — template entries naming another business's shift / rule profile
SELECT 'template_entry.shift' AS kind, e.id, e.shift_template_id, t.business_id AS owner_business_id,
       s.business_id AS referenced_business_id
FROM shift_template_entries e
JOIN shift_templates t ON t.id = e.shift_template_id
JOIN shifts s          ON s.id = e.shift_id
WHERE s.business_id <> t.business_id
UNION ALL
SELECT 'template_entry.rule_profile', e.id, e.shift_template_id, t.business_id, p.business_id
FROM shift_template_entries e
JOIN shift_templates t     ON t.id = e.shift_template_id
JOIN shift_rule_profiles p ON p.id = e.shift_rule_profile_id
WHERE p.business_id <> t.business_id;

-- Q2  BUG-031 — assignments whose employee / shift / rule profile is not of the branch's business
SELECT sa.id, sa.user_id, sa.branch_id, b.business_id AS branch_business_id,
       u.business_id AS user_business_id, s.business_id AS shift_business_id,
       p.business_id AS rule_profile_business_id, sa.source_template_id
FROM shift_assignments sa
JOIN branches b ON b.id = sa.branch_id
JOIN users u    ON u.id = sa.user_id
JOIN shifts s   ON s.id = sa.shift_id
LEFT JOIN shift_rule_profiles p ON p.id = sa.shift_rule_profile_id
WHERE u.business_id <> b.business_id
   OR s.business_id <> b.business_id
   OR (p.id IS NOT NULL AND p.business_id <> b.business_id);

-- Q3  BUG-032 — settlement ledger rows naming another business's payment method
SELECT t.id, t.remaining_deposit_balance_id, t.transaction_type, t.amount, t.created_at,
       r.business_id AS balance_business_id, pm.business_id AS payment_method_business_id, pm.active
FROM remaining_deposit_balance_transactions t
JOIN remaining_deposit_balances r ON r.id = t.remaining_deposit_balance_id
JOIN payment_methods pm           ON pm.id = t.payment_method_id
WHERE pm.business_id <> r.business_id;
-- (A same-business but currently inactive method cannot be told apart from one deactivated later.)

-- Q4  BUG-033 — bank statements naming another business's branch
SELECT bs.id, bs.file_name, bs.business_id, br.business_id AS branch_business_id, bs.created_at
FROM bank_statements bs
JOIN branches br ON br.id = bs.branch_id
WHERE br.business_id <> bs.business_id;

-- Q5  BUG-034 — laundry batches naming another business's towel type / operator
SELECT lb.id, lb.batch_number, lb.status, lb.business_id,
       tt.business_id AS towel_type_business_id, op.business_id AS operator_business_id
FROM laundry_batches lb
JOIN towel_types tt ON tt.id = lb.towel_type_id
LEFT JOIN users op  ON op.id = lb.operator_id
WHERE tt.business_id <> lb.business_id
   OR (op.id IS NOT NULL AND op.business_id <> lb.business_id);

-- Q6  BUG-029 — new laundry / stock-issue activity at a branch AFTER its last
--     recorded deactivation (the branch is still inactive). Only deactivations
--     made through OrganizationAccess::DeactivateBranch (PR #87) have an audit
--     entry; a branch deactivated earlier is not covered.
WITH deactivated AS (
  SELECT b.id AS branch_id, b.business_id, MAX(a.created_at) AS deactivated_at
  FROM branches b
  JOIN audit_logs a ON a.auditable_type = 'Branch' AND a.auditable_id = b.id AND a.action = 'deactivate'
  WHERE b.active = false
  GROUP BY b.id, b.business_id
)
SELECT 'towel_transfer.created' AS kind, t.id AS record_id, d.business_id, d.branch_id, d.deactivated_at,
       t.created_at AS happened_at
FROM towel_transfers t
JOIN deactivated d ON d.branch_id IN (t.source_branch_id, t.destination_branch_id)
WHERE t.created_at > d.deactivated_at
UNION ALL
SELECT 'towel_transfer.dispatched_to_inactive', t.id, d.business_id, d.branch_id, d.deactivated_at, t.dispatched_at
FROM towel_transfers t
JOIN deactivated d ON d.branch_id = t.destination_branch_id
WHERE t.dispatched_at > d.deactivated_at
UNION ALL
SELECT 'towel_adjustment.created', ta.id, d.business_id, d.branch_id, d.deactivated_at, ta.created_at
FROM towel_adjustments ta
JOIN deactivated d ON d.branch_id = ta.branch_id
WHERE ta.created_at > d.deactivated_at
UNION ALL
SELECT 'laundry_batch.created', lb.id, d.business_id, d.branch_id, d.deactivated_at, lb.created_at
FROM laundry_batches lb
JOIN deactivated d ON d.branch_id = lb.laundry_branch_id
WHERE lb.created_at > d.deactivated_at
UNION ALL
SELECT 'stock_issue.created', si.id, d.business_id, d.branch_id, d.deactivated_at, si.created_at
FROM stock_issues si
JOIN deactivated d ON d.branch_id = si.branch_id
WHERE si.created_at > d.deactivated_at
UNION ALL
SELECT 'stock_issue.submitted', si.id, d.business_id, d.branch_id, d.deactivated_at, si.submitted_at
FROM stock_issues si
JOIN deactivated d ON d.branch_id = si.branch_id
WHERE si.submitted_at > d.deactivated_at
UNION ALL
SELECT 'stock_issue.approved', si.id, d.business_id, d.branch_id, d.deactivated_at, si.approved_at
FROM stock_issues si
JOIN deactivated d ON d.branch_id = si.branch_id
WHERE si.approved_at > d.deactivated_at
ORDER BY business_id, branch_id, happened_at;

-- FOLLOW-UP F1 for Q2 — attendance records matched to the assignments Q2
-- returned (their penalties used the foreign shift). Replace the ids, uncomment:
-- SELECT ar.id, ar.user_id, ar.work_date, ar.shift_assignment_id
-- FROM attendance_records ar
-- WHERE ar.shift_assignment_id IN (/* assignment ids from Q2 */);

ROLLBACK;
