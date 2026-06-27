# Till Handover & Daily Reconciliation

## Overview

This feature tracks the physical custody of a branch's cash till throughout a business day. It answers the operational question "who is responsible for the till right now?" and gives management an audit trail for each business day's cash activity.

The design principle is **structural state**: status is never stored as an enum or flag. Every piece of state is derived from the shape of the data at query time.

---

## Domain Concepts

### PaymentMethod

Defines the types of payment a branch accepts (Cash, Visa, Instapay, etc.). Each method has a `settlement_type` (`cash`, `card`, `ewallet`, `voucher`, `other`) and a `cash_like?` predicate. Only cash-like methods require ATM deposits.

### TillHandover

The core record. Each handover is one link in a **linked list** (via `previous_handover_id`) that represents the chain of custody for a given branch and business date.

There are two handover types:
- **transfer** — from one receptionist to another. The recipient must explicitly accept it to become the new holder.
- **depositor** — the current holder declares themselves today's depositor and assumes end-of-day responsibility. This type is self-accepted immediately (`accepted_at = Time.current` on create).

**State derivation:**
- `pending?` — `accepted_at IS NULL`
- `accepted?` — `accepted_at IS NOT NULL`
- `holder` — for transfers: `to_user`; for depositor: `from_user`
- `current_holder_for(branch, date)` — the chain tail: accepted, with no next handover (`where.missing(:next_handover)`)

**Chain integrity** is enforced by two partial unique DB indexes (no application-level locking needed):
1. `UNIQUE(previous_handover_id) WHERE previous_handover_id IS NOT NULL` — each handover has at most one successor
2. `UNIQUE(branch_id, business_date) WHERE previous_handover_id IS NULL` — each branch/day has exactly one chain head

### TillHandoverLine

Records the amounts declared when creating a handover — one row per payment method. Stores `collected_amount` and `refund_amount`. Net: `collected_amount - refund_amount`.

### TillDeposit

Records a physical ATM cash drop by the depositor. Only cash-like payment methods are valid. Deposits are voided (not deleted) via the `Voidable` concern.

### DailyReconciliation

A thin verification record: `(business, branch, business_date, verified_by, verified_at, notes)`. **No financial data is stored here.** All amounts are computed at query time from `TillHandoverLine` and `TillDeposit`. Created lazily when a manager verifies a day.

---

## State Transitions

### Receptionist workflow

```
Day starts — no chain yet
        │
        ▼
First receptionist creates a handover
        │
  ┌─────┴──────┐
  │            │
transfer   depositor
  │            │
  ▼            ▼
Recipient   Immediately accepted
must accept    (no separate step)
  │
  ▼
New holder — can transfer or become depositor
  │
  ▼
Depositor records ATM deposits until all cash is banked
```

### Receptionist states (derived in controller)

| State | Condition | Primary action |
|---|---|---|
| `:no_branch` | No current ShiftAssignment | None — contact manager |
| `:incoming_handover` | Pending transfer addressed to current user | Accept the Till |
| `:depositor` | Current user is holder AND handover type is depositor | Record a Deposit |
| `:holding` | Current user is holder AND handover type is transfer | Hand Over / Become Depositor |
| `:waiting_outgoing` | Pending transfer from current user, not yet accepted | Waiting |
| `:held_by_other` | Chain exists but current user is not the holder | Info only |
| `:no_activity` | No chain started for today | Hand Over / Become Depositor |

### Management audit questions (day view)

1. Who currently holds the till? → `TillHandover.current_holder_for(branch, date)`
2. Who became today's depositor? → chain entry with `handover_type = 'depositor'`
3. Were all transfers accepted? → `@chain.select { transfer? && pending? }` is empty
4. How much was deposited? → `TillDeposit` sum for the day
5. Remaining cash balance? → cash-like collected amounts minus total deposited
6. Has this day been verified? → `DailyReconciliation#verified?`

---

## Business Rules

1. **Only the current holder may create the next handover.** Enforced in `TillHandoverCreator#validate_actor_is_current_holder!` using `current.holder == @actor`.

2. **A depositor-type handover is self-accepted.** `accepted_at = Time.current` is set in `build_handover` before `save!`. No separate accept step required.

3. **The chain is linear.** Each link has at most one successor (DB unique index on `previous_handover_id`). Attempting to create a fork raises `RecordNotUnique`, caught and returned as a user-facing error.

4. **Only cash-like methods can be deposited.** Validated on `TillDeposit` via `payment_method_must_be_cash_like`.

5. **DailyReconciliation stores no financial data.** Amounts are always computed from `TillHandoverLine` and `TillDeposit` joins. This prevents any drift between the audit trail and the stored totals.

6. **The first chain link of the day is protected against race conditions.** The DB partial unique index `WHERE previous_handover_id IS NULL` ensures only one chain head per (branch, business_date). `TillHandoverCreator` catches `RecordNotUnique` and returns a clear error.

---

## Key Files

### Models
| File | Purpose |
|---|---|
| `app/models/payment_method.rb` | Payment methods per business, with settlement type |
| `app/models/till_handover.rb` | Core custody chain link |
| `app/models/till_handover_line.rb` | Per-method amounts for one handover |
| `app/models/till_deposit.rb` | ATM cash drops by the depositor |
| `app/models/daily_reconciliation.rb` | Thin verification record; all finance computed |

### Services
| File | Responsibility |
|---|---|
| `Finance::TillHandoverCreator` | Validates current holder, builds chain link, creates lines |
| `Finance::TillHandoverAcceptor` | Sets `accepted_at` on a pending transfer |
| `Finance::TillDepositRecorder` | Creates a TillDeposit, validates depositor ownership |
| `Finance::DailyReconciliationVerifier` | `find_or_create_by!` + sets `verified_by/at` |

### Controllers
| File | Routes | Audience |
|---|---|---|
| `TillHandoversController` | `GET /my_shift`, `/till_handovers/new`, `POST /till_handovers`, `PATCH /till_handovers/:id/accept` | Receptionists |
| `TillDepositsController` | `GET /till_deposits/new`, `POST /till_deposits`, `PATCH /till_deposits/:id/void` | Receptionists (depositor only) |
| `Finance::DailyReconciliationsController` | `GET /finance/daily_reconciliations`, `GET /finance/daily_reconciliations/day`, `PATCH /finance/daily_reconciliations/verify_day` | Management |

### Policies
| File | Key rules |
|---|---|
| `TillHandoverPolicy` | `my_shift?` = `create_shift_closing`; `accept?` = pending transfer addressed to current user |
| `TillDepositPolicy` | `create?` = depositor-type handover where actor is `from_user` |
| `DailyReconciliationPolicy` | `verify?` = `verify_daily_reconciliation` or owner |

---

## Migrations

| Migration | Effect |
|---|---|
| `20260625000002_finalize_payment_methods` | Renames `payment_category → settlement_type`, adds `supports_refunds` |
| `20260625000003_create_till_handover_tables` | Creates `till_handovers`, `till_handover_lines`, `till_deposits`, `daily_reconciliations` with all FK + chain integrity indexes |
| `20260625000004_fix_daily_reconciliation_unique_index` | Fixes unique index to include `business_id` scope |

---

## Permissions

| Permission | Group | Purpose |
|---|---|---|
| `create_shift_closing` | shifts | Access to `/my_shift` and till handover creation |
| `view_daily_reconciliation` | finance_overview | Read-only access to the management audit views |
| `verify_daily_reconciliation` | finance_overview | Can verify a day (creates the DR record) |
| `manage_payment_methods` | expense_administration | CRUD on payment methods |

---

## Common Pitfalls

**`current_user.branch` does not exist.** Branch membership is determined by `ShiftAssignment`. Always use `current_user.shift_assignments.current.first&.branch`.

**`Date.current` is not business-aware.** Always use `BusinessDay.current(context: current_user.business)` to get the business-timezone-adjusted current date.

**Do not add status enums.** The state of any handover is fully derivable from `accepted_at` (nil = pending) and the chain structure. Adding an enum would create a second source of truth that can drift.

**`includes` + `order` on a joined table.** Use `eager_load` instead of `includes` when you need to `ORDER BY` a column on the associated table.
