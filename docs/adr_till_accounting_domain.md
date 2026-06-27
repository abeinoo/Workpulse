# ADR: Till Accounting Domain Architecture

**Status:** Accepted  
**Date:** 2026-06-26  
**Scope:** Finance module — `DailyReconciliation`, `TillSession`, `TillHandover`, `TillDeposit`

---

## Context

The till module was originally built with `TillSession` as the central object. Controllers, services, and policies started from `TillSession.open_for(branch)` or `TillSession.open_for!(branch)`. `DailyReconciliation` was a secondary record that was sometimes created as a side-effect.

This caused:
- Orphaned `DailyReconciliation` records when `TillSession` was found but no linked reconciliation existed
- `ActionController::UrlGenerationError` when routes expected a reconciliation ID but the record was nil
- Scattered accounting state across two models
- No clear single record to use as the accounting identity for a business day

The architecture was refactored across three phases (June 2026) to establish `DailyReconciliation` as the **Aggregate Root** of the till domain. This ADR documents the final, stable design and the rules that must not be violated going forward.

---

## 1. Domain Overview

### DailyReconciliation

The **accounting record** for a single business day at a single branch. It is the primary object used by every business workflow: opening a day, closing it, recording deposits, assigning a depositor, and verifying the totals.

**Single responsibility:** Own the complete accounting lifecycle of one till day.

Every permission check, route, policy scope, service call, and report must start from `DailyReconciliation`. No other model in this domain plays that role.

---

### TillSession

The **operational custody record** attached to a `DailyReconciliation`. It stores only the three things that change during the day as custody passes between cashiers:

- Who currently holds the till (`current_holder_id`)
- Who will deposit it at the end of the day (`depositor_id`)
- Who closed it (`closed_by_id`)

**Single responsibility:** Track physical custody of the till during the business day.

`TillSession` has no lifecycle of its own. It exists only as an internal implementation detail of `DailyReconciliation`. It must never store accounting timestamps, states, branch identity, or deposit data.

---

### TillHandover

A **custody event** — the record that one person handed the till to another. Accepted handovers advance the custody chain. The final handover (a self-deposit) closes the day.

**Single responsibility:** Record a single transfer of till custody between two people.

---

### TillDeposit

A **deposit event** — the record that cash (or a cash-equivalent) was physically deposited against a closed day. Multiple partial deposits are allowed.

**Single responsibility:** Record one physical deposit against a reconciliation.

---

## 2. Aggregate Root

`DailyReconciliation` is the Aggregate Root of the till domain.

In Domain-Driven Design, the Aggregate Root is the only object through which external code may interact with the cluster. All invariants of the cluster are enforced through it.

### Why DailyReconciliation, not TillSession?

`TillSession` is a physical operational concept — it describes what is happening to the cash tin right now. `DailyReconciliation` is the accounting concept — it is the record of what happened on a given business day, which survives long after the cashier has gone home.

Accounting records:
- Are the identity for a business day (`business_date`, `branch_id`)
- Are the subject of finance reports and audits
- Drive the permission model (who can view, verify, manage)
- Own the state machine (`open → closed → deposited → verified`)

None of those responsibilities belong to `TillSession`.

### The consequence

**No business workflow should start from `TillSession`.**

There is no route, controller, policy scope, or service that takes a `TillSession` as its entry point. All routes use `DailyReconciliation` IDs. All scopes query `DailyReconciliations`. All services receive a `DailyReconciliation` as their first argument.

---

## 3. Model Relationships

```
DailyReconciliation (Aggregate Root)
│
├── has_one  :till_session          (1:1, dependent: destroy)
│   └── belongs_to :daily_reconciliation
│       owns: current_holder, depositor, closed_by
│
├── has_many :till_handovers        (1:N, dependent: destroy)
│   └── belongs_to :daily_reconciliation
│       owns: from_user, to_user, accepted_at, amounts
│
└── has_many :till_deposits         (1:N, dependent: restrict_with_error)
    └── belongs_to :daily_reconciliation
        owns: payment_method, amount, deposited_at, voided_at
```

### What each relationship means

**→ TillSession (1:1, destroy)**  
Created atomically with the DR. Destroyed when the DR is destroyed. Never created independently. There is exactly one TillSession per DailyReconciliation, enforced by a unique index on `till_sessions.daily_reconciliation_id`.

**→ TillHandovers (1:N, destroy)**  
The handover timeline for the day. Each handover belongs to the DR. The DR's handover collection is the complete, ordered record of who held the till and when.

**→ TillDeposits (1:N, restrict)**  
The deposit record for the day. Restricted from cascade deletion — deposits are financial records and must not disappear if the DR were ever deleted. Deletion of a DR with deposits is blocked at the database level.

---

## 4. Lifecycle

```
DailyReconciliation.create_for!(branch:, created_by:)
    │
    ├─ Creates DailyReconciliation { state: "open", opened_at: now }
    └─ Creates TillSession { current_holder: created_by }
           (both in a single transaction — atomic)

       ↓

TillHandover (hand_to_colleague)
    │
    ├─ Validates: actor is current holder, no pending outgoing, minimum amounts met
    ├─ Creates TillHandover { from_user, to_user, amounts }
    ├─ To-user calls accept → TillSession.current_holder updated
    └─ Repeat as many times as needed during the shift

       ↓

TillHandover (self_deposit — closes the day)
    │
    ├─ Validates: actor is current holder
    ├─ Creates TillHandover { self_deposit: true }
    ├─ DailyReconciliation updated: { state: "closed", closed_at: now, business_date: fresha_date }
    └─ TillSession updated: { closed_by: actor, depositor: actor }

       ↓

DailyReconciliationsController#assign_depositor (optional)
    │
    └─ TillSession.depositor updated (DR untouched)

       ↓

TillDeposit (one or more partial deposits)
    │
    ├─ Validates: DR is closed, actor is the depositor on TillSession
    ├─ Creates TillDeposit { daily_reconciliation, payment_method, amount }
    └─ Repeat until fully deposited

       ↓

DailyReconciliationVerifier
    │
    ├─ Validates: DR is closed (not open)
    └─ DailyReconciliation updated: { verified_at: now, verified_by: actor }

       ↓

Completed — DR is the permanent accounting record for the day.
TillSession retains only who closed it and who deposited it (audit trail).
```

---

## 5. Responsibilities

| Responsibility | Owner | Field(s) |
|---|---|---|
| Accounting lifecycle state | `DailyReconciliation` | `state` |
| Day open timestamp | `DailyReconciliation` | `opened_at` |
| Day close timestamp | `DailyReconciliation` | `closed_at` |
| Business date (Fresha date) | `DailyReconciliation` | `business_date` |
| Deposit transition timestamp | `DailyReconciliation` | `deposited_at` |
| Verification timestamp | `DailyReconciliation` | `verified_at` |
| Verifying manager | `DailyReconciliation` | `verified_by_id` |
| Branch identity | `DailyReconciliation` | `branch_id` |
| Business identity | `DailyReconciliation` | `business_id` |
| Current physical holder | `TillSession` | `current_holder_id` |
| Designated depositor | `TillSession` | `depositor_id` |
| Who closed the day | `TillSession` | `closed_by_id` |
| Custody transfer record | `TillHandover` | `from_user_id`, `to_user_id`, `accepted_at` |
| Handover amounts | `TillHandoverAmount` | per-payment-method amounts |
| Session totals (end-of-day snapshot) | `TillSessionAmount` | per-payment-method totals |
| Deposit record | `TillDeposit` | `amount`, `payment_method_id`, `deposited_at` |
| Reports and dashboards | `DailyReconciliation` | queried directly, no TillSession join |
| Permission scoping | `DailyReconciliation` | `branch_id` scoped directly |

---

## 6. Invariants

These rules are enforced at both the model validation layer and the database constraint layer. They must never be violated.

### Structural invariants (enforced by DB constraints)

1. **One open `DailyReconciliation` per branch.**  
   Unique partial index: `idx_dr_one_open_per_branch ON daily_reconciliations (branch_id) WHERE state = 'open'`

2. **`TillSession` cannot exist without a `DailyReconciliation`.**  
   NOT NULL constraint + FK on `till_sessions.daily_reconciliation_id`.

3. **Each `DailyReconciliation` has at most one `TillSession`.**  
   Unique index: `idx_till_sessions_unique_dr ON till_sessions (daily_reconciliation_id)`

4. **Every `TillHandover` belongs to exactly one `DailyReconciliation`.**  
   NOT NULL constraint + FK on `till_handovers.daily_reconciliation_id`.

5. **Every `TillDeposit` belongs to exactly one `DailyReconciliation`.**  
   NOT NULL constraint + FK on `till_deposits.daily_reconciliation_id`.

6. **Deposits cannot be cascade-deleted with their reconciliation.**  
   `has_many :till_deposits, dependent: :restrict_with_error`

### Business invariants (enforced by services and policies)

7. **A `TillSession` is only ever created inside `DailyReconciliation.create_for!`.**  
   No controller, service, or model may call `TillSession.create!` directly.

8. **Only the current holder may create a handover.**  
   Enforced by `TillHandoverCreator#validate_actor_is_holder!`

9. **Only one pending outgoing handover at a time.**  
   Enforced by `TillHandoverCreator#validate_no_pending_outgoing!`

10. **Deposits may only be recorded against a closed reconciliation, by the designated depositor.**  
    Enforced by `TillDepositRecorder` and `TillDepositPolicy#create?`

11. **`TillSession` stores no accounting state.**  
    `TillSession` has no `state`, `branch_id`, `business_id`, `opened_at`, `closed_at`, `deposited_at`, or `fresha_date` columns.

12. **`DailyReconciliation` stores no operational custody state.**  
    `DailyReconciliation` has no `current_holder_id`, `depositor_id`, or `closed_by_id` columns.

---

## 7. Public API

These are the only approved external entry points into the till domain. Everything else is internal.

### `DailyReconciliation.create_for!(branch:, created_by:)`

The **only** way to open a new till day. Creates the `DailyReconciliation` and its `TillSession` atomically in a single transaction. Raises on failure.

```ruby
# Correct
DailyReconciliation.create_for!(branch: branch, created_by: current_user)

# Never do this
TillSession.create!(branch: branch, ...)
TillSession.open_for!(branch)
```

### `DailyReconciliation.open_for(branch)`

Finder only. Returns the currently open `DailyReconciliation` for the given branch, or `nil`. **Does not create anything.**

```ruby
# Correct — finder
dr = DailyReconciliation.open_for(branch)

# Never do this — the old pattern
TillSession.open_for(branch)
```

### `Finance::TillHandoverCreator.new(actor:, daily_reconciliation:, params:).call`

Creates a handover. Closes the day when `params[:self_deposit]` is `"1"`.

### `Finance::TillHandoverAcceptor.new(handover, actor:).call`

Accepts a pending handover. Updates `TillSession.current_holder`.

### `Finance::TillDepositRecorder.new(daily_reconciliation, actor:, params:).call`

Records a deposit. Validates that the DR is closed and the actor is the designated depositor.

### `Finance::DailyReconciliationVerifier.new(daily_reconciliation, actor:, notes:).call`

Verifies a reconciliation. Updates only `DailyReconciliation`.

---

## 8. Future Development Rules

### Never do these things

**Never create a `TillSession` directly.**  
`TillSession.create!` must not appear anywhere outside of `DailyReconciliation.create_for!`. If you need to create a session, use `create_for!`.

**Never start a workflow from `TillSession`.**  
There is no `TillSession.open_for`, `TillSession.open_for!`, or any class method that serves as a workflow entry point. If you find yourself looking up a `TillSession` first, you are in the wrong place. Look up the `DailyReconciliation` first.

**Never add accounting fields to `TillSession`.**  
`TillSession` must not gain `state`, `opened_at`, `closed_at`, `deposited_at`, `business_date`, `branch_id`, or `business_id`. These belong on `DailyReconciliation`. If you feel the need to duplicate them onto `TillSession`, it is a sign the feature should be attached to `DailyReconciliation` instead.

**Never add custody fields to `DailyReconciliation`.**  
`DailyReconciliation` must not gain `current_holder_id`, `depositor_id`, or `closed_by_id`. Operational questions ("who has the till right now?") are answered by `dr.till_session.current_holder`.

**Never introduce business logic into `TillSession`.**  
`TillSession` should have no service objects, no state machine, and no callbacks that trigger domain actions. It is a plain data record.

**Never query deposits or handovers from `TillSession`.**  
`TillSession` has no `has_many :handovers` and no `has_many :deposits`. All deposit and handover queries go through `DailyReconciliation`.

**Never bypass `DailyReconciliation` in routes or policies.**  
All routes in the till domain use `DailyReconciliation` IDs (`daily_reconciliation_id`). All policy scopes query `daily_reconciliations.branch_id` directly.

### Rules for new features

**Any new end-of-day feature must attach to `DailyReconciliation`.**  
If you are building something that happens during a business day (e.g., cash counts, discrepancy notes, manager sign-off), add it as an association on `DailyReconciliation`, not on `TillSession`.

**New permissions must be checked against `DailyReconciliation`.**  
Policy classes receive a `DailyReconciliation` record. `TillSession` should not appear as a `record` in any `Policy` class.

**New reports must start from `DailyReconciliation`.**  
All aggregate queries (totals, counts, state distributions) should query `DailyReconciliation` directly. Accessing `TillSession` from a report is only acceptable when the data is genuinely operational (e.g., who deposited it) and has no home on `DailyReconciliation`.

**If `TillSession` needs a new column, ask first.**  
A new column on `TillSession` is a code smell. Before adding one, confirm: (a) is this operational data that changes during the day as custody moves? If not, it belongs on `DailyReconciliation`.

---

## Schema Reference (post-Phase-3)

### `daily_reconciliations`
`id`, `branch_id`, `business_id`, `state`, `opened_at`, `closed_at`, `deposited_at`, `business_date`, `verified_at`, `verified_by_id`, `notes`, `created_at`, `updated_at`

### `till_sessions`
`id`, `daily_reconciliation_id`, `current_holder_id`, `depositor_id`, `closed_by_id`, `created_at`, `updated_at`

### `till_handovers`
`id`, `daily_reconciliation_id`, `from_user_id`, `to_user_id`, `accepted_at`, `self_deposit`, `fresha_date`, `float_amount`, `from_notes`, `accepted_notes`, `notes`, `created_at`, `updated_at`

### `till_deposits`
`id`, `daily_reconciliation_id`, `payment_method_id`, `deposited_by_id`, `amount`, `deposited_at`, `reference`, `notes`, `voided_at`, `voided_by_id`, `void_reason`, `created_at`, `updated_at`

---

## Decision

Adopt `DailyReconciliation` as the permanent Aggregate Root of the till accounting domain. All code that was written against the old `TillSession`-first architecture has been removed. This document is the contract for all future development.
