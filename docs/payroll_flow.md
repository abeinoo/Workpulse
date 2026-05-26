# Payroll Flow — Source of Truth

## Overview

Payroll moves through a strict linear state machine, starting from `draft` and
advancing through review stages to `paid`. All monetary computations live in
service objects; controllers and views contain no business logic.

---

## 1. Status State Machine

```
draft  →  under_review  →  branch_review_completed  →  finalized  →  paid
  ↑___________↲  (regenerate resets to draft; only possible from draft)
```

| Status | Who can advance | Action |
|---|---|---|
| `draft` | owner / manage_payroll | Generate, regenerate |
| `under_review` | manager / manage_payroll | `submit_for_review` |
| `branch_review_completed` | branch manager | `complete_branch_review` |
| `finalized` | owner / finalize_payroll | `finalize` |
| `paid` | owner | `mark_paid` |

**Locked**: Any status other than `draft`. Locked periods reject new adjustments
and block regeneration. The `PayrollPeriod#locked?` and `PayrollPeriod#lock_reason`
methods express this.

---

## 2. Generation Lifecycle

### 2a. New Period — `Payroll::PeriodGenerator`

**Source of truth**: `app/services/payroll/period_generator.rb`

```
PeriodGenerator.call(business:, year:, month:, generated_by:)
  → Finds or creates PayrollPeriod (one per business per month)
  → Raises if existing period is not draft
  → ObligationDeduction.destroy_all (restores balance before recalc)
  → PayrollEntry.destroy_all (clears stale entries)
  → For each active user with a salary profile:
      EntryCalculator.call(period:, user:, business:)
  → period.update!(generated_at: Time.current)
```

**Idempotent**: Re-running on a `draft` period clears and rebuilds all entries
while preserving the period record and its ID.

### 2b. Regeneration — `Payroll::Regenerator`

**Source of truth**: `app/services/payroll/regenerator.rb`

Wraps `PeriodGenerator` with:
- Pre-snapshot via `Payroll::SnapshotService` (so diffs are visible)
- `PayrollAuditLog` with `action_type: :regenerated`
- Safe `rescue StandardError` returning a `Result` object (never raises to controller)

Called from: `PayrollPeriodsController#regenerate` (owner / manage_payroll only).

---

## 3. Per-Employee Calculation — `Payroll::EntryCalculator`

**Source of truth**: `app/services/payroll/entry_calculator.rb`

For each active user:

```
EntryCalculator.call(period:, user:, business:)
  1. Salary::DailyRateCalculator.for(user:, business:, date: period.period_start)
     → Finds salary profile effective on period_start (not today)
     → Returns nil if no profile → entry skipped
  2. Load AttendanceRecord for period (includes shift → penalty_rules)
  3. attendance_line_items(records, daily_rate, overtime_multiplier)
     → For each checked-out, non-absent record:
         a. EmployeeRequest lookup: approved late_permission / early_leave minutes
         b. Attendance::PenaltyCalculator.calculate (with permission override)
         c. Salary::OvertimeCalculator.calculate
  4. absence_line_items — monthly employees: absent days × daily_rate deduction
  5. Payroll::AdvanceDeductor — approved advances this period
  6. Payroll::ObligationDeductor — recurring obligation installments
  7. PayrollAdjustment query — approved adjustments for this user/period
  8. Compute net_salary:
       base_salary - total_deductions + total_overtime + total_bonuses
       - already_paid_total - advances_deducted - obligations_deducted
  9. Transaction: create PayrollEntry + all PayrollLineItems
```

---

## 4. Salary / Rate Calculation

### Daily Rate — `Salary::DailyRateCalculator`

**Source of truth**: `app/services/salary/daily_rate_calculator.rb`

```
monthly salary → base_amount / business.working_days_per_month
daily  salary  → base_amount (already per day)
```

**Profile selection**: Always uses `effective_from <= period_start` (historical
accuracy for past-month regeneration).

### Overtime — `Salary::OvertimeCalculator`

```ruby
overtime_hours = [worked_minutes - shift.duration_minutes - grace_minutes, 0].max / 60.0
overtime_pay   = daily_rate * overtime_multiplier * (overtime_hours / shift_hours)
```

Grace minutes come from `Business#overtime_grace_minutes` (default 0).

### Penalties — `Attendance::PenaltyCalculator`

**Source of truth**: `app/services/attendance/penalty_calculator.rb`

```
1. Resolve shift type (fixed_time or hour_based)
2. Look up PenaltyRule for the actual late/early minutes
3. fixed_amount? → rule.deduction_value SAR
   percentage?   → daily_salary * rule.deduction_value / 100
```

Permission offsets are applied **before** rule lookup in `EntryCalculator`.

---

## 5. Adjustments

### Single Adjustment — `PayrollAdjustmentsController`

Created at review time (linked to a specific period + entry). Auto-approved for
owners; requires `pending_review` for managers. Immediately materialised as a
`PayrollLineItem` and `entry.recalculate_totals!` called.

### Bulk Adjustment — `Adjustments::BulkCreateService`

Validates all rows first (no partial saves). The `user.business` must match
`current_user.business` — enforced via `PayrollAdjustment`'s `user_belongs_to_business`
validation.

### Adjustment Approval/Rejection — `Payroll::LineItemReviewer`

Updates `PayrollAdjustment.review_status`, syncs the corresponding `PayrollLineItem`,
and calls `entry.recalculate_totals!`. Fires `PayrollAuditLog` and optionally
`Payroll::NotificationService`.

---

## 6. Review Workflow

```
Manager:  submit_for_review → status: under_review
Branch manager: complete_branch_review → PayrollPeriodBranchReview.status: completed
              (all branches completed) → status: branch_review_completed
Owner/Finance: finalize → status: finalized
Owner: mark_paid → status: paid
```

**Branch reviews**: Each branch associated with the period gets a
`PayrollPeriodBranchReview` row. The period advances to `branch_review_completed`
only when all pending reviews are complete (`PayrollPeriod#reviewable?`).

**Bulk approve**: `PayrollPeriodsController#approve_all_pending` approves all
`pending_review` line items across the period in a single transaction, then
recalculates each affected entry exactly once.

---

## 7. Snapshots — `Payroll::SnapshotService`

Before each regeneration a snapshot of the current entries is saved as JSON in
`PayrollSnapshot` (linked to the period). This gives auditors a diff-friendly
history of what changed between runs.

---

## 8. Audit Trail — `PayrollAuditLog`

Every significant payroll action writes a `PayrollAuditLog`:

| action_type | Trigger |
|---|---|
| `generated` | PeriodGenerator initial creation |
| `regenerated` | Payroll::Regenerator |
| `submitted_for_review` | SubmitForReview service |
| `branch_review_completed` | BranchReviewCompleter |
| `finalized` | Approver.advance |
| `paid` | Approver.advance |
| `adjustment_added` | PayrollAdjustmentsController#create |
| `adjustment_approved` | approve / bulk-approve |
| `adjustment_rejected` | reject |
| `adjustment_removed` | destroy |
| `deleted` | PayrollPeriodsController#destroy |

---

## 9. Notification Triggers

All payroll notifications go through `Payroll::NotificationService.notify(event:, period:, actor:)`.

| Event | Recipients |
|---|---|
| `submitted_for_review` | Owner |
| `branch_review_completed` | Owner |
| `finalized` | All users with view_payroll or owner |
| `paid` | All users with view_payroll or owner |
| `regenerated` | Owner |
| `adjustment_approved` | The affected employee (`context[:user]`) |
| `adjustment_rejected` | The affected employee (`context[:user]`) |

Notification failures are swallowed (logged but do not disrupt workflow).

---

## 10. Anomaly Detection — `Payroll::AnomalyDetector`

**Source of truth**: `app/services/payroll/anomaly_detector.rb`

Runs on a period's entries at display time (not stored). Checks:
- Entries with high deduction-to-base ratio
- Entries with pending line items
- Unusual overtime concentrations
- Employees missing from the period

---

## 11. Key Invariants

| Invariant | Enforcement |
|---|---|
| One period per business per month | DB unique index on (business_id, period_year, period_month) |
| Regeneration only on draft periods | PeriodGenerator raises; Regenerator returns Result.error |
| Adjustments cannot be created after submission | `PayrollAdjustment#period_not_locked` validation |
| `user.business == adjustment.business` | `user_belongs_to_business` model validation |
| Net salary formula is canonical | Only computed in EntryCalculator and `PayrollEntry#recalculate_totals!` |
| Advance/obligation deduction is always re-derived | ObligationDeduction.destroy_all before regeneration; balance restored by callback |
| Audit log written for every state change | Each controller action creates PayrollAuditLog before redirecting |

---

## 12. Deduction Formula Reference

```
net_salary = base_salary
           - total_deductions          (late + early-leave penalties + absence + manual deductions)
           + total_overtime
           + total_bonuses             (cash_incentive + commission)
           - already_paid_total        (bonuses reported in total_bonuses but already disbursed)
           - advances_deducted
           - obligations_deducted
```

**total_deductions** = sum of negative line items (absolute value)
**total_bonuses** = sum of positive line items (including already-paid)
**already_paid_total** = sum of positive line items marked `already_paid: true`

---

## 13. Calculation Chain

```
PayrollPeriodsController#create / #regenerate
  └─ Payroll::PeriodGenerator (or via Payroll::Regenerator)
       ├─ Payroll::SnapshotService (pre-regeneration only)
       └─ [for each active user]
            └─ Payroll::EntryCalculator
                 ├─ Salary::DailyRateCalculator
                 ├─ AttendanceRecord.for_period (with shift → penalty_rules)
                 ├─ Attendance::PenaltyCalculator (per record)
                 ├─ Salary::OvertimeCalculator   (per record)
                 ├─ Payroll::AdvanceDeductor
                 ├─ Payroll::ObligationDeductor
                 ├─ PayrollAdjustment query (approved, this user/period)
                 └─ PayrollEntry + PayrollLineItem creation (transaction)
```
