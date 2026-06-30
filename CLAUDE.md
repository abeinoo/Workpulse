# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```bash
# Run all tests
bundle exec rspec

# Run a single spec file
bundle exec rspec spec/services/finance/till_handover_creator_spec.rb

# Run a specific example by line number
bundle exec rspec spec/models/payroll_entry_spec.rb:42

# Lint
bin/rubocop

# Security scans (run in CI)
bin/brakeman --no-pager
bin/bundler-audit
bin/importmap audit

# Database
bin/rails db:migrate
bin/rails db:migrate:status

# Rails console
bin/rails console

# In production (Docker)
docker compose exec web ./bin/rails console
docker compose exec web ./bin/rails db:migrate
```

## Architecture

### Multi-tenancy

Every record belongs to a `Business`. Users belong to one business. `Branch` is the operational sub-unit. Most domain records carry both `business_id` and `branch_id`. Business **owners** implicitly have all permissions — never check owner? in business logic; it is only checked in policies via `user.owner?`.

### Authorization (Pundit)

All policies inherit `ApplicationPolicy`. Use `can?(:permission_name)` (delegates to `user.can?`) for permission checks. Never use `user.owner?` directly in action methods — it is handled in `ApplicationPolicy`.

**Data scoping** has two flavours:
- **Employee scope** (`EmployeeScope`) — limits which *users* a viewer can see. Resolved via `filter_by_data_scope` in `ApplicationPolicy::Scope`.
- **Branch scope** (`BranchScope`) — limits which *branches* a viewer can access. Resolved via `filter_by_branch_scope`. Used by finance, custody, expenses, and daily-reconciliation management permissions.

Scope levels: `self → branch → area → business`. Configured per-permission on `PermissionRole#permission_scopes`. `nil` scope means "use the hierarchy default."

When a policy method receives the **class** as `record` (e.g. `authorize SomeModel, :action?` for collection-level actions), guard accordingly — never call instance predicates like `record.open?` on a class. Add a dedicated `bulk_*?` policy method for collection gates.

### Services

All mutating business logic lives in `app/services/`. Services return a `Result` struct:

```ruby
Result = Struct.new(:ok, :record, :error, keyword_init: true) { def ok? = ok }
```

Call services in controllers, check `result.ok?`, redirect or re-render. Services raise `ActiveRecord::RecordInvalid` or `ArgumentError` internally and rescue them into `Result.new(ok: false, …)`. Never put business logic in controllers or models.

Services include `AuditLoggable` and call `log_audit(actor:, auditable:, action:, metadata: {})` — failures are swallowed and logged, never abort the primary operation.

### Permissions system

`PermissionRole` holds a `permissions` array and a `permission_scopes` hash. Groups are defined in `PermissionRole::PERMISSION_GROUPS`. Scopable permissions are listed in `SCOPABLE_PERMISSIONS`. Dependencies (e.g. `manage_attendance` requires `view_attendance`) are enforced by `PERMISSION_DEPENDENCIES` — always satisfy dependencies when adding a new permission.

**Adding a new permission**: add it to the correct group in `PERMISSION_GROUPS`, add any dependency to `PERMISSION_DEPENDENCIES`, add the `can?(:new_permission)` check in the appropriate policy, add it to `DEFAULT_PERMISSIONS_BY_ROLE_TYPE` if applicable.

### Daily Reconciliation domain (Finance)

`DailyReconciliation` is the aggregate root for a cashier business day. It has one `TillSession` (custody state: holder, depositor, closer) and many `TillHandover`s (custody chain). The chain is a linked list; state is **derived from data shape**, never stored as a flag.

Key derivations:
- `current_holder` — the chain tail: accepted handover with no successor (`where.missing(:next_handover)`)
- `depositor` — `till_session.depositor`
- Day state — `DailyReconciliation#state` enum: `open → closed → deposited → verified`

`TillHandoverCreator` is the single entry point for all handover creation. `DailyReconciliation.create_for!` is the only place a `TillSession` may be created.

`RemainingDepositBalance` tracks cash shortfalls after day close. It uses an append-only ledger (`RemainingDepositBalanceTransaction`) — never modify past transactions. Statuses: `open → settled | written_off`. Actions (settle, write_off, reassign) go through dedicated service objects.

### Namespaces and routing

| Namespace | Prefix | Purpose |
|---|---|---|
| *(root)* | — | Cashier-facing: till handovers, deposits, my_shift |
| `admin/` | `admin_` | Super-admin: users, branches, roles, devices |
| `api/v1/` | `api_v1_` | Mobile JSON API |
| `finance/` | `finance_` | Finance ops: expenses, custody, reconciliations, RDB |
| `inventory/` | — | Inventory: products, receipts, issues, transfers |
| `performance/` | — | Performance evaluation module |

### Concerns

- `AuditLoggable` — `log_audit` helper, included in models that need audit trails.
- `Voidable` — soft-delete via `voided_at`; `active` scope excludes voided records.
- `ImmutableDocument` — prevents updates after a record is finalized.
- `Attachable` — shared Active Storage validations (content type, size).

### Solid Queue / recurring jobs

Background jobs run via Solid Queue. Recurring schedules are in `config/recurring.yml`. The `background` queue must have a worker running in production. Add new recurring jobs to `recurring.yml`; restart the Solid Queue supervisor to pick them up.

### Localization

Full EN + AR with RTL CSS. Translation files under `config/locales/`. `Business#default_locale` and `User#preferred_locale` drive locale selection. Always add both `en` and `ar` keys when adding user-facing strings.

### Testing

RSpec with FactoryBot and Shoulda Matchers. Factories in `spec/factories/`. Shared contexts and helpers in `spec/support/`. Tests are organized to mirror `app/` structure — model specs, service specs, policy specs, request specs.

---

## Project Philosophy

WorkPulse is an **audit-first ERP**. Every business action must be traceable to a person, a time, and a reason. Correctness and traceability are never sacrificed for convenience or speed of delivery.

- Financial history is immutable. Records are voided or reversed with compensating entries, never edited or deleted.
- Every workflow must preserve a complete, chronological audit trail visible to management.
- State is derived from data shape wherever possible rather than stored as a redundant flag.
- The system must be resilient to partial failures — operations either complete fully (within a transaction) or leave no trace.
- Business rules encoded here represent real operational and legal constraints, not preferences. Treat them as hard invariants.

---

## Business Rules

These rules must never be violated by any feature, fix, or refactor.

**Daily Reconciliation**
- `DailyReconciliation` is the source of truth for a business day at a branch. One per branch per business day — enforced by a DB unique index.
- A cashier cannot perform any operation (sales, deposits, closing) before the till session is open and their custody is established.
- The business day is not the same as the calendar day. Always use `BusinessDay.current(context: business)` — never `Date.today` or `Date.current`. The business day rolls over at `business.business_day_start_hour`, not midnight.

**Till Custody Chain**
- Till custody is a **continuous, unbroken chain**. Every transfer of physical cash from one person to another must be represented by a `TillHandover` record that the recipient explicitly accepts.
- The current holder is always the tail of the accepted chain — derived, never stored.
- A cashier cannot begin working before receiving the opening float. No deposits, no closings, no handovers are permitted until custody is established for the day.
- `TillHandoverCreator` is the **only** entry point for creating handovers. Never write to `TillHandover` or `TillSession` directly from controllers or other services.

**Remaining Deposit Balance**
- `RemainingDepositBalance` uses an **append-only ledger** (`RemainingDepositBalanceTransaction`). Past ledger entries are never modified or deleted.
- Every financial event on a balance (partial settlement, write-off, reassignment) appends a new transaction. The current state is computed from the ledger, not stored redundantly.
- No two open balances may exist for the same underlying shortage. Duplicate prevention is a DB-level concern (unique indexes) plus service-level guards.

**Financial Records**
- Inventory documents (`GoodsReceipt`, `StockIssue`, `StockTransfer`) are immutable once posted — `ImmutableDocument` raises on any `destroy` attempt. Reverse with a compensating document.
- `TillDeposit` and `CustodyTransaction` records are voided (`Voidable`), never deleted. The void and its reason remain in the ledger.
- Custody balances are computed as `SUM(amount)` over non-voided transactions — never cached in a writable column without a corresponding transaction row.

---

## Architecture Rules

**Controllers orchestrate only.** A controller's job is: authorize, call a service, redirect or render. No financial calculations, no domain decisions, no direct model mutations beyond `find` and simple attribute reads.

**Business logic belongs in Services.** Every workflow that changes financial state, transitions a record through a lifecycle, or touches more than one model belongs in `app/services/`. Services must be callable from the console and from jobs without a request context.

**Views never calculate financial values.** Totals, balances, and aggregates are computed in the controller or model and assigned to instance variables. Views only format and display. Use `format_currency(amount)` (from `ApplicationHelper`) for all money display — never `number_to_currency` directly in views, as it ignores the business's configured currency and locale.

**The Audit Timeline is built only in `build_timeline_events`.** (`Finance::DailyReconciliationsController#build_timeline_events`). To add a new event type: push a hash `{ type: :symbol, time: Time, actor: User, data: record }` in that method, add a matching `when :symbol` block in the view's case statement. Never build timeline data in the view or in a model.

**Never bypass services from controllers.** Even for "simple" state changes. The service is where validations, audit logging, and transactional integrity live. A controller that calls `record.update!(state: "closed")` directly has no audit trail, no guards, and no compensation path.

**Aggregate roots own their children.** `DailyReconciliation` owns `TillSession`, `TillHandover`, `TillDeposit`, `TillSessionAmount`. Never create or destroy these children without going through the DR's service layer. `DailyReconciliation.create_for!` is the only place a `TillSession` is created.

**Scope resolution has a single path.** Employee visibility goes through `EmployeeScope`; branch visibility goes through `BranchScope`. Never write ad-hoc `where(branch_id: ...)` in a policy — use `filter_by_branch_scope` so scope configuration changes propagate automatically.

**Services accept IDs for the aggregate they mutate.** When a service calls `update!`, `save!`, or any state transition on an AR record, that record must be loaded by the service itself at the top of `call` — not accepted as a pre-loaded object from the controller. The controller passes `record.id`; the service calls `Model.where(business_id: actor.business_id).find(id)`. This prevents Rails' `inverse_of` / `save_collection_association` from autosaving blank controller-side records (built for Pundit authorization) into the service's transaction. Reference implementations: `Finance::TillDepositRecorder`, `Finance::DailyReconciliationVerifier`, `Finance::TillHandoverCreator`, `Finance::OpeningFloatReceiver`.

---

## Money Rules

- **Never delete financial records.** Inventory documents use `ImmutableDocument`. Transactions use `Voidable`. If neither concern applies and you find yourself calling `.destroy`, stop and reconsider.
- **Never overwrite historical balances.** Balance state is always the result of applying all transactions in order. If you need to correct a balance, post a correcting transaction.
- **Store amounts as `decimal` in the database.** Use `.to_d` when reading from params. Never use floats for money. Never use integer cents — the business currency and precision are variable.
- **Every financial action must generate an audit event** via `log_audit`. This is non-negotiable for custody transfers, settlements, write-offs, payroll transitions, and expense approvals.
- **Custody amounts are stored signed.** A debit is negative; a credit is positive. Balance = `SUM(amount)` on non-voided rows. Do not store a separate `balance` column that drifts from the ledger.
- **Corrections are append-only.** A payroll override, a deduction waiver, a balance reassignment — all append a new record preserving the original. The original is never mutated.

---

## UI / UX Principles

- **Primary actions must always be visually obvious.** The next step in a workflow must be the most prominent element on the page — not buried in a menu.
- **Financial state must never be hidden.** Open balances, pending handovers, and unverified reconciliations must be surfaced proactively, not found by drilling in.
- **Every workflow guides the user step by step.** If a precondition is not met (e.g. no opening float received), show a clear blocking state with an explanation and the exact action needed — not a generic error.
- **The Audit Timeline is the primary interface for understanding what happened.** When a manager asks "what happened to this till today?", the answer is always the timeline on the DR show page — in chronological order, with actor and timestamp for every event.
- **Users should never need to infer financial state.** Status badges, totals, and outstanding amounts are always shown. A closed balance should look closed; a pending handover should look pending. Design for operational staff under time pressure.
- **Destructive or irreversible actions require explicit confirmation and a reason.** Write-offs, voids, and waivers always capture a `notes` or `reason` field. The UI must not allow these to be submitted without one.

---

## Extension Points

**Adding a new financial workflow**
1. Create a service in `app/services/` returning a `Result` struct. Accept the aggregate's **ID**, not the AR object — load it with `Model.where(business_id: actor.business_id).find(id)` at the top of `call`.
2. Include `AuditLoggable` and call `log_audit` inside the transaction.
3. Add a policy method (instance-level for single-record actions, `bulk_*?` for class-level).
4. Add routes and a thin controller action that calls the service, passing `record.id`.
5. Push timeline events into `build_timeline_events` for any new event types.

**Adding a new permission**
1. Add it to the correct group in `PermissionRole::PERMISSION_GROUPS`.
2. Add dependencies to `PERMISSION_DEPENDENCIES` (and verify the reverse `PERMISSION_DEPENDENTS` index updates automatically).
3. Add `can?(:new_permission)` checks to the relevant policy.
4. Add to `DEFAULT_PERMISSIONS_BY_ROLE_TYPE` for applicable role archetypes.
5. If it controls cross-branch data visibility, add it to `DR_MANAGEMENT_PERMISSIONS` or `BRANCH_SCOPABLE_PERMISSIONS` as appropriate.

**Adding a timeline event type**
1. Push `{ type: :your_event, time: ..., actor: ..., data: ... }` in `build_timeline_events`.
2. Add a `when :your_event` branch in `show.html.erb`'s case statement.
3. Add i18n keys for both `en` and `ar`.

**Adding a new recurring job**
1. Create the job class in `app/jobs/`.
2. Register it in `config/recurring.yml` with a cron schedule and queue name.
3. Restart the Solid Queue supervisor in production.

---

## Performance Guidelines

- **No N+1 queries.** Every controller action that renders a collection must preload all associations touched in the view. Use `.includes(...)` at the query site — the show page `set_reconciliation` method is the reference example for deep preloading.
- **Always preload before the view.** Associations needed in `build_timeline_events` must be included in the controller's base query. The timeline builder must not trigger any database queries — it operates only on already-loaded records.
- **Prefer SQL aggregation over Ruby enumeration for financial totals.** Use `scope.sum(:amount)`, `scope.count`, and `scope.average(Arel.sql(...))` rather than loading records and calling `.map.sum`. The DR summary figures in `DashboardController` are the reference pattern.
- **Scope counts separately from the display set.** Compute summary counts (open, overdue, outstanding total) on the base scope before applying filters, so the page header always reflects the business-wide picture, not just the filtered view.
- **Large reconciliation days must remain performant.** The DR show page must load in one database round-trip per association group — never per-handover or per-transaction. If a new association is added to the DR domain, add it to `set_reconciliation`'s `includes` chain.
