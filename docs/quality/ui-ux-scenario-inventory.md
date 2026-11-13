# WorkPulse UI/UX and workflow scenario inventory

**Status:** baseline established 2026-11-13 on `main` `36cb6f7`. This is the
working register of the Product, UI/UX and Engineering Quality Program: every
user-facing workflow, who can run it, how it should behave, how it actually
behaves, and which test proves it. It is updated with every audit wave and
every fix PR, alongside `docs/quality/deferred-bugs.md` (defects, `BUG-NNN`)
and the attendance roadmap (`docs/architecture/attendance-requirements-and-cost-allocation-plan.md`).

## 1. How the inventory is built

1. **Route baseline (generated).** `script/quality/route_inventory.rb` lists
   every application route with its domain (from the dependency inventory), its
   authorization style and the request / system specs that reference it, into
   `docs/quality/ui-ux-route-inventory.csv`. "Referenced" is a text match, so a
   zero is a candidate gap to verify, not proof of no coverage.
2. **Scenarios (audited).** Each workflow is walked end to end — creation,
   validation, approval, review, finalization, reporting — per role, and
   recorded in §4 with the columns below. A scenario is "Verified" only when it
   was exercised in a running application (request spec or browser system
   spec), never because a page rendered.
3. **Browser runs.** Real workflows run in headless Chrome through the existing
   Capybara system-spec harness (`spec/system`), at desktop (1366 px), tablet
   (820 px) and mobile (390 px) widths, in English (LTR) and Arabic (RTL).
   Accessibility checks per screen: labels, keyboard order and focus, visible
   focus state, contrast of status badges, readable error feedback.
4. **States per screen:** success, validation error, empty, loading / pending
   (Turbo), backend failure (service refusal, lock / audit failure),
   unauthorized, and duplicate submission.

**Scenario columns:** ID · domain / feature · role and permissions ·
preconditions and data · actions · expected result · actual result · UI/UX
issues · backend / API behaviour · automated coverage · severity / priority ·
fix PR or roadmap reference.

**Severity:** S1 data integrity or money · S2 authorization / security ·
S3 broken or blocked workflow · S4 usability (mobile, clarity) · S5 polish.
Priority follows the program order: data integrity and financial correctness →
authorization → payroll / attendance / leave / lifecycle → broken workflows →
mobile → accessibility and consistency → performance and polish.

## 2. Baseline (generated, `main` 36cb6f7)

| Domain | Routes | Controllers | Routes with no request/system spec reference |
|---|---:|---:|---:|
| Attendance & Payroll | 160 | 29 | 5 |
| Workforce | 157 | 21 | 54 |
| Finance & Sales | 193 | 24 | 70 |
| Inventory & Purchasing | 180 | 30 | 45 |
| Organization & Access | 43 | 10 | 18 |
| Reporting | 6 | 5 | 0 |
| Infrastructure | 2 | 1 | 0 |
| **Total** | **741** | **120** | **192** |

* **Authorization:** every controller authorizes with Pundit except a known set
  that authorizes another way — verified, no finding: the device-token
  biometric API (`api/v1/punches`), self-service and session screens
  (`attendance`, `api/v1/attendance`, `api/v1/sessions`, `profile/passwords`,
  `preferences`, `locale`, Devise), `inventory/settings` (explicit
  `policy(...).index?` checks), `laundry/towel_balances` and
  `laundry/reports/branch_consumption` (permission + assignable branches),
  `inventory/reports` (base-controller access + scope), `admin/settings`,
  `birthday_celebrations` (own record).
* **System (browser) specs:** 12 files today (`spec/system`, plus `admin`,
  `finance`, `inventory` folders) — the browser coverage is thin compared with
  741 routes; most workflow coverage is request-level.

### 2.1 Candidate coverage gaps (to verify in the waves below)

| Domain | Controller | Actions without a spec reference |
|---|---|---|
| A&P | `bulk_adjustments` | import, template, preview_import, confirm_import, create |
| F&S | `finance/balance_requests` | full lifecycle (new, create, edit, update, submit, approve, reject, cancel, mark_paid, destroy) |
| F&S | `finance/bank_statements` | create, edit/update, destroy, rematch, sample_csv |
| F&S | `finance/expenses` | create, edit/update, destroy |
| F&S | `finance/expense_categories`, `expense_types`, `expense_tags`, `payment_methods` | CRUD (and move_up / move_down) |
| F&S | `finance/recurring_expenses` | create, update, destroy |
| F&S | `finance/remaining_deposit_balances` | reassign, write_off |
| F&S | `finance/reports` | approvals, custody_balances, custody_transactions, negative_balances, recurring, shared_allocation |
| F&S | `finance/sales_imports`, `pos_imports` | create, preview, column mapping, confirm, destroy |
| F&S | `finance/custody_transactions`, `deposit_responsibility_transfers#cancel`, `till_refunds#new` | as listed |
| I&P | `inventory/brands`, `product_categories`, `suppliers`, `warehouses` | CRUD |
| I&P | `inventory/goods_receipts` | create, edit/update |
| I&P | `inventory/stock_issues` | create, update, void, destroy |
| I&P | `inventory/stock_transfers` | create, void |
| I&P | `inventory/stock_adjustments`, `warehouse_supplies` | create / update |
| I&P | `laundry/laundry_batches` | create, reverse |
| I&P | `laundry/towel_adjustments`, `towel_transfers`, `towel_types` | create (and CRUD) |
| OA | `admin/branches`, `admin/permission_roles` | create, update, destroy |
| OA | `admin/settings`, `admin/user_passwords`, `profile/passwords` | update / edit |
| WF | `admin/departments`, `job_titles`, `evaluation_templates`, `shift_rule_profiles`, `shift_templates` | CRUD |
| WF | `shift_assignments` | create, edit/update, confirm_end, destroy |
| WF | `employee_data_requests` | create, update |
| WF | `performance/observations`, `performance/reviews` | CRUD, submit, finalize |

Many of these are exercised under other names (service specs, shared helpers);
each row is closed by either pointing to the existing test or adding one.

## 3. Audit waves (program order)

| Wave | Scope | Method | Status |
|---|---|---|---|
| W1 | Data integrity and money: payroll generation → review → recalculation → finalization → payment (holds, advances, obligations); deposits, custody, expenses, remaining deposit balances; stock postings and voids | request + system specs per role; backend-failure states; duplicate submission | planned |
| W2 | Authorization: every role preset × every workspace; scope (self / branch / area / business); cross-business isolation | policy and request matrix (extends `permission_matrix_verification_spec`) | planned |
| W3 | Employee lifecycle, attendance, leave (with the roadmap: R3.2 G6–G9, R3.3, R3.4, R4, R5, R6b, R7) | each roadmap gate ships with its UI workflow and acceptance specs | in progress with the roadmap |
| W4 | Broken / incomplete workflows from W1–W3 and the §2.1 gaps | fix PRs | planned |
| W5 | Mobile and responsive (390 / 820 px), Arabic RTL | system specs at widths, both locales | planned |
| W6 | Accessibility and consistency (labels, focus, contrast, terminology, confirmations, destructive actions) | system specs + checklist | planned |
| W7 | Performance and polish (N+1, page weight) | query-count specs on collection pages | planned |

## 4. Scenario register

| ID | Domain / feature | Role / permissions | Preconditions | Actions | Expected | Actual | UI/UX issues | Backend / API | Coverage | Sev / prio | Fix / reference |
|---|---|---|---|---|---|---|---|---|---|---|---|
| WF-HOL-01 | WF / Holiday Calendar | `manage_holidays` (owner) | business | add, edit, delete a holiday | one per date, audited, year view | Verified | — | `Scheduling::HolidayCalendar` | `spec/requests/holidays_spec.rb`, service spec | — | R6, PR #131 |
| WF-HOL-02 | WF / Holiday Calendar | employee without `manage_holidays` | — | open `/holidays` | refused | Verified | — | policy | `holidays_spec.rb`, `holiday_policy_spec.rb` | — | R6 |
| WF-HOL-03 | WF / Holiday Calendar | `manage_holidays` | audit store failing | edit / delete | change refused, message shown | Verified (service, request redirect) | browser run pending (W5/W6) | `log_audit!` | `holiday_calendar_spec.rb` | S4 | R6 |
| WF-REQ-01 | WF / attendance requirement change | HR (`manage_employees`, business scope) | rollout off (R3.2) | change requirement | refused: not enabled | Verified (service) | screen arrives in G8 | changer `:rollout_inactive` | changer spec | — | R3.2 G5 (#132), G8 |
| WF-REQ-02 | WF / attendance requirement change | HR | rollout on, period Under Review | backdated change | refused, period and stage named | Verified (service, two connections) | screen G8 | D4 protocol §19.14 | changer + concurrency specs | — | R3.2 G5 |
| AP-SFR-01 | A&P / Submit for Review | `submit_payroll_review` | Draft period; a stale page | submit twice | one submission; the second refused with a message | Verified | message wording is technical ("Period must be draft…") | `SubmitForReview` lock | submit specs | S5 | R3.2 G4 (#130); wording → W6 |
| API-ROUTE-01 | API / routing | API client | — | `GET /api/v1/shifts/new`, `/api/v1/shift_assignments/new`, `/api/v1/users…` | not routed | routes exist without actions (users: no controller) → not found | — | dead routes | — | S5 | BUG-047 |

Rows are added per wave; every confirmed defect also gets a `BUG-NNN` entry or a fix PR.
