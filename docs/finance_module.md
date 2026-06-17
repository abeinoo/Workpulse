# Financial Operations & Expense Management — Implementation Summary

Status: **Complete** (10 phases) · Namespace: `finance` · Currency: business-configured (locale-aware rendering).

The module covers expense categories/types/tags, expenses (single-branch, shared, and request workflow), custody accounts/transactions/settlements (العهد), recurring expenses, branch revenue, eleven reports + branch profitability, and a finance dashboard. Full EN + AR localization with RTL.

---

## 1. New permissions (14)

Added to `PermissionRole::PERMISSION_GROUPS`. None are auto-assigned — an admin must add them to permission roles (business **owners implicitly have all permissions**).

**Group `expenses`**
| Permission | Grants |
|---|---|
| `view_expenses` | See expenses, catalogs, recurring lists |
| `create_expenses` | Create / submit expenses (requires `view_expenses`) |
| `edit_expenses` | Edit draft/pending/rejected expenses |
| `approve_expenses` | Approve / reject pending expenses |
| `pay_expenses` | Mark approved expenses paid (incl. pay-from-custody) |
| `manage_expense_categories` | CRUD expense categories |
| `manage_expense_types` | CRUD expense types |
| `manage_expense_tags` | CRUD expense tags |
| `manage_recurring_expenses` | CRUD recurring templates + "Generate now" |

**Group `custody`**
| Permission | Grants |
|---|---|
| `view_custody` | See custody accounts, balances, ledgers |
| `manage_custody` | Create accounts, record transactions, void (requires `view_custody`) |
| `settle_custody` | Create/submit/approve/reject settlements (requires `view_custody`, `manage_custody`) |

**Group `expense_reports`**
| Permission | Grants |
|---|---|
| `view_expense_reports` | View all finance reports + branch profitability (business-wide) |
| `manage_branch_revenue` | Enter/edit monthly branch revenue (requires `view_expense_reports`) |

**Branch-scopable** (self / branch / area / business): `view_expenses`, `create_expenses`, `edit_expenses`, `approve_expenses`, `pay_expenses`, `view_custody`, `manage_branch_revenue`. These limit *which branches'* records a user can see/write. `view_expense_reports` is intentionally business-wide.

---

## 2. Database migrations (9)

Run in order with `bin/rails db:migrate`. All additive; all reversible.

| Migration | Adds |
|---|---|
| `20260615000001_create_expense_catalog_tables` | `expense_categories`, `expense_types`, `expense_tags` |
| `20260615000002_create_expenses_and_allocations` | `expenses`, `expense_allocations`, `expense_taggings` |
| `20260615000003_create_custody_tables` | `custody_accounts`, `custody_settlements`, `custody_transactions` |
| `20260615000004_create_recurring_expenses` | `recurring_expenses`, `recurring_expense_allocations`; adds `expenses.source_recurring_expense_id` |
| `20260615000005_create_branch_revenues` | `branch_revenues` |
| `20260615000006_add_branch_to_inventory_consumption` | nullable `branch_id` on `stock_issues` + `inventory_movements` |
| `20260615000007_add_profitability_reporting_indexes` | composite `[branch_id, expense_date]` / `[branch_id, occurred_on]`; drops the now-redundant single-column branch_id indexes |
| `20260616000001_add_vendor_reference_to_expenses` | `expenses.vendor_reference` (optional supplier invoice/receipt no.) |
| `20260616000002_add_unique_recurring_generation_index` | partial unique index `expenses(source_recurring_expense_id, expense_date)` — duplicate-generation backstop |

---

## 3. Routes (under `/finance`)

| Resource | Path | Notes |
|---|---|---|
| Dashboard | `GET /finance` | `finance_root` |
| Expenses | `resources :expenses` | + member `submit`, `approve`, `reject`, `pay` (PATCH) |
| Categories / Types / Tags | `resources …, except: :show` | catalog CRUD |
| Branch revenues | `resources :branch_revenues, except: :show` | |
| Recurring expenses | `resources :recurring_expenses` | + member `generate` (POST) |
| Custody accounts | `resources :custody_accounts` | |
| └ Transactions | nested `only: [:create]` | + member `void` (PATCH) |
| └ Settlements | nested `only: [:new,:create,:show]` | + member `submit`, `approve`, `reject` (PATCH) |
| Reports | `GET /finance/reports` + 12 report paths | each supports `.csv` |

Reports: `expenses_by_branch`, `expenses_by_category`, `expenses_by_type`, `expenses_by_vendor`, `expense_trend`, `shared_allocation`, `recurring`, `custody_balances`, `custody_transactions`, `outstanding_custody`, `approvals`, `branch_profitability`.

---

## 4. Manual deployment steps

1. **Migrate:** `bin/rails db:migrate` (9 migrations above).
2. **Recurring job:** ensure the Solid Queue **recurring scheduler** is running in production. `config/recurring.yml` registers `generate_due_recurring_expenses` (class `Finance::GenerateDueRecurringExpensesJob`, queue `background`, **daily 06:30**). Confirm a worker processes the `background` queue.
3. **Assets:** none new — the forms reuse the existing `line-items` Stimulus controller. No importmap/JS changes.
4. **Grant permissions:** in Admin → Permission Roles, add the finance permissions to the appropriate roles (owners already have access). Without this, no non-owner sees the finance module.
5. **Restart** the app (and the Solid Queue supervisor) to pick up `recurring.yml`.

No environment variables, secrets, or third-party services are introduced.

---

## 5. Data migration / backfill for existing businesses

**No backfill is required for the module to function.** All migrations are additive and new tables start empty. Notes:

- **Catalogs are not seeded.** Each business creates its own expense categories/types/tags (no default seeder shipped). Consider seeding common categories (Rent, Utilities, Marketing, …) per business if a turnkey start is desired.
- **Inventory `branch_id` is nullable; existing rows stay NULL** and are *unattributed* in branch profitability — by design. Only **go-forward** stock issues (which now require a branch) feed per-branch inventory cost. No historical backfill is needed; if historical attribution is wanted, map past `stock_issues.warehouse → branch` manually (out of scope).
- **New stock issues require a branch** (validation `on: :create`). The stock-issue form, controller, and CSV importer were updated to capture it — confirm operational staff know to select a branch.
- **Branch revenue is manual.** Profitability shows revenue only for branch-months entered under Finance → Branch Revenue (or via `manage_branch_revenue`).
- **Permissions** must be added to existing roles (step 4 above) — not automatic.

---

## 6. User guide

### Expense requests
1. Finance → Expenses → **New Expense**. Pick category (and optional type), amount, date, vendor, optional **vendor reference** (supplier invoice/receipt no.), branch, tags, and attach invoices/receipts.
2. For a **shared expense**, leave the branch blank and add **allocation** rows (branch + %). Choose *By percentage* or *Split equally*; allocations must total 100%. Allocated amounts are computed automatically.
3. Save as **draft**, then **Submit for Approval** → status becomes *Pending Approval*. (A manager who lacks `pay_expenses` effectively files a "request" this way.)

### Approvals
- A user with `approve_expenses` opens a pending expense and clicks **Approve** or **Reject** (rejection needs a reason).
- **Self-approval is blocked** — you cannot approve/reject an expense you created. **Exception: business owners** may approve their own.
- Every transition is written to the audit log (who/when, status change), visible in the expense **History** section.

### Paying from custody
1. Open an **Approved** expense.
2. If you hold `manage_custody`, the **Mark Paid** control includes a dropdown of **any custody account you manage** (accountant, branch-manager, ops floats — shown as *name (holder)*), plus "— Mark paid (no custody)".
3. Choose an account and pay: the expense is marked **Paid**, a **negative custody "expense" transaction** is posted (linked to the expense), and the account balance is refreshed — atomically.
4. If the chosen account's balance can't cover the amount, **payment is blocked** and nothing changes. Selecting "no custody" just marks it paid without a deduction.

### Recurring expenses
1. Finance → Recurring → **New Recurring Expense**: category/type, amount, **frequency** (weekly/monthly/quarterly/yearly), start date, optional end date, branch (or shared allocations), vendor. `Next run` defaults to the start date.
2. The daily job creates a **Pending Approval** expense when a template is due (catching up missed periods), advances the schedule, and links each generated expense back to its template. **Recurring expenses are never auto-paid** — they go through normal approval.
3. **Generate Now** on a template forces the current period immediately. Duplicate generation for the same date is prevented (DB unique index + row lock).
4. Deactivating a template stops generation; generated expenses are unaffected.

### Branch profitability reports
- Finance → Reports → **Branch Profitability** (or the dashboard card). Pick a **month/year**.
- Per branch: **Revenue − Payroll − Inventory Cost − Branch Expenses = Net Profit**, with a totals row.
  - *Revenue* = branch revenue entered for that month.
  - *Payroll* = that branch's monthly payroll gross (base + overtime + bonuses).
  - *Inventory Cost* = **consumption** (outbound stock-issue movements valued at moving-average cost) attributed to the branch — **not** purchases.
  - *Branch Expenses* = approved/paid expenses for the branch + its allocated share of shared expenses.
- All reports export to **CSV** (numeric values, Excel-friendly: no currency symbols/grouping). Enter monthly **Branch Revenue** for the profit line to be meaningful.

---

## Architecture notes (for maintainers)

- **Authorization:** Pundit policies + record-level **branch write-scope** (`ApplicationPolicy#branches_within_scope?`) + self-approval blocks at both policy and service layers. Custody scoping via `CustodyAccountPolicy::Scope`.
- **Money integrity:** custody amounts are stored **signed**; balances are `SUM` of non-voided transactions (cache + `computed_balance`). Custody transactions are **voided, never deleted**. Allocation amounts reconcile to the expense total to the cent.
- **Concurrency:** recurring generation uses a row lock + partial unique index. Document numbers (`EXP-`, `STL-`) use per-business advisory-lock sequencing.
- **Profitability inventory cost is source-agnostic** — it reads outbound `InventoryMovement` rows, so a future Fresha consumption importer writing those rows needs no report changes.
- **Tests:** 53 finance RSpec examples (services/jobs/policies) — recurring generation + duplicate prevention, profitability, allocation reconciliation, approval workflow incl. owner exception + pay-from-custody, custody balances/settlements/voiding, branch-scoped access. CSV pure-numeric output is asserted.

### Known limitations / future work
- Recurring schedules drift at month-end (day-31 → 28 after February) and a long-deactivated template catches up on reactivation (capped at 24 periods) — both accepted.
- Reports are business-wide (no per-branch report scoping).
- No native `.xlsx` (CSV only). No Fresha importer yet. Custody transaction form shows all fields (no per-type JS toggle).
