# Multi-Unit Inventory and Nested Packaging — Final Architecture Design and Implementation Plan (Phase 3)

**Revision:** Phase 3, **revision 6** (design + implementation record) · **Date:** 2026-11-22
**Status:** Implemented on branch `feature/multi-unit-packaging` (local commit, not pushed or merged) under Decision 22 — see §21 for what was built, what deviates from this design and what remains. Rollout still needs the Production read-only gate (§17). The three migrations are applied to the test database and, with the owner's explicit approval (2026-11-22), to Development; Production is not migrated.
**History:** revision 1 = the Phase 3 architecture report delivered in the planning conversation (never stored in the repository); revision 2 = the first version of this file; revision 3 = 16 decisions and the BUG-070 investigation; revision 4 = Decisions 17–20; revision 5 = Decision 21 (closed-period costing policy); revision 6 = this version (Decision 22 and the implementation record, §21). See §20 Change log.

| Label | Meaning |
|---|---|
| **[Fact]** | Verified by read-only inspection of the code, schema, repository or Development database on 2026-11-22 (commit `a41970d3`; `origin/main` = `ca33edbb`). Revisions 4 and 5 ran no database query; their new facts come from reading code, the schema file and the bug register only |
| **[Decision n]** | One of the 22 approved decisions in §1 |
| **[Earlier]** | Business decision approved in the Phase 2 / Phase 3 rounds before these 22 (§1.6) |
| **[Proposal]** | Technical design / implementation proposal; needs implementation approval per phase |
| **[Proposed severity]** | Severity recommendation awaiting user approval (§15.3); not a final classification |
| **[Unresolved]** | Open question still needing evidence or a user decision (§19.1) |

---

## 1. Approved decisions

### 1.1 Phase 3 decisions (approved in the previous review)

| # | Decision | Where |
|---|---|---|
| 1 | **Measure integration — INNER.** `products.measure_amount` is the content of the innermost packaging level; `Inventory::Packaging::Configurator` is the primary writer and keeps it equal to level 1; higher levels live in `product_packaging_levels`. | §4.5 |
| 2 | **Base-unit changes — LOCK.** The base unit is locked once inventory movements exist; later changes only through the audited Unit Conversion document. | §4.6 |
| 3 | **Hierarchy — MAXIMUM 4 LEVELS.** One linear chain per product, at most four levels including the innermost; no alternative packaging in V1. | §4 |
| 4 | **Repackaging — STOCKTAKE ONLY.** Reclassification only through Stocktake, including packaging-only corrections with a zero base difference; no repackaging workflow or adjustment reason. | §8 |
| 5 | **Receipt voiding — RESTORE.** Restore packages still free; remove the opened/unavailable portion as base quantity through the planner; never reseal; void preview shows the impact and is recalculated at confirmation. | §9 |
| 6 | **Issue approval — NON-BLOCKING WARNING.** The issue stays approved with its reservation; strict package availability is enforced at posting. | §10.4 |
| 7 | **Purchase remaining — PURCHASE UNIT.** Displayed in the purchase unit with fractional remainder / base equivalent when needed; base quantity canonical. | §7.1, §12 |
| 8 | **BUG-070 – BUG-074 — AUDIT ALL.** Audit definitions, behaviour, root causes, dependencies, fixes and tests; invent nothing. | §15 |

### 1.2 Decisions approved in the latest review

| # | Decision | Where |
|---|---|---|
| 9 | **BUG-070 — investigate first.** No replay order is chosen or approved yet; the Development discrepancy must be explained first; posting order is not prescribed merely because normal posting uses it. | §16 |
| 10 | **P1 scope** includes BUG-071, BUG-072, and BUG-070's investigation (fix only once the root cause is understood and a fix approved); replay-audit entries only if the verified design requires them. | §18 P1 |
| 11 | **Unit-cost display:** up to 8 dp, trailing zeros removed, no scientific notation, consistent across screens, exports and reports; storage precision and money rounding unchanged. | §12 |
| 12 | **Formal registration** of BUG-070 – BUG-074 in the repository's bug registry is a future planning task; this document specifies the entries but does not register them. | §15.4 |
| 13 | **BUG-074 is fixed in P2, before P4.** | §15, §18 P2 |
| 14 | **Measure synchronisation:** Configurator (primary writer and validator) **and** a database trigger (defensive integrity layer). | §4.5 |
| 15 | **Purchase remaining** displays up to **3 dp**, trailing zeros removed, base equivalent where needed; never rounds in a way that changes the remaining quantity or permits over-receipt. | §7.1, §12 |
| 16 | **Production read-only profile is mandatory** before the rollout plan is approved; read-only only; not run during this task. | §17 |

Decision 10's clause "replay-audit entries only if the verified design requires them" is now settled by Decision 17 (always required when the stored average changes). Decision 11's whole-number case is made explicit by Decision 18. Neither is weakened.

### 1.3 Final review decisions (approved for revision 4)

| # | Decision | Where |
|---|---|---|
| 17 | **Audit every recalculated average-cost change.** Every recalculation that changes a product's stored average writes an audit record (product, previous and new average, reason, triggering document, actor, time, operation reference), in the same transaction; none when the value is unchanged; none on failure; trigger type identified; history never overwritten; system actor defined; authorisation, idempotency and failure tests. | §11.1 |
| 18 | **Whole-number unit costs display without decimal zeros:** `25.00000000` → `25`, `25.50000000` → `25.5`, `0.70000000` → `0.7`, `0.70400000` → `0.704`, `0.00000125` → `0.00000125`; up to 8 dp, no scientific notation; display only, on screens, reports, exports and audit displays. | §12 |
| 19 | **Negative balance during replay: stop and diagnose.** Recalculation is isolated per product; a product whose replay reaches a negative balance is stopped — no new average, no partial result, no success audit — and a diagnostic report is produced; other products continue only if isolation is safe, otherwise the whole operation stops; never insert opening balances, skip, silently reorder or modify history. | §11.2 |
| 20 | **Severity classification:** Claude proposes a severity for BUG-070 – BUG-074 with justification, using the register's existing conventions; proposal only; formal registration still waits for the user's approval of the severities. | §15.3 |

### 1.4 Business decision approved for revision 5

| # | Decision | Where |
|---|---|---|
| 21 | **Closed accounting periods are never silently changed by a back-dated inventory document.** A back-dated supplier invoice keeps its original date (e.g. 5 October), but when that date's period is already closed its inventory-costing impact is recognised in the **first open accounting period** (November, when entered on 10 November with October closed). The system must not retroactively recalculate the closed period's inventory costs, issues or reports because of the late document. | §16.9 |

Scope of Decision 21 as approved: **back-dated purchase invoices** (in WorkPulse: cost-bearing goods receipts, §16.9.1). Its extension to other operations is **not** assumed; the separate policy questions are listed in §16.9.6 and §19.1. Decision 21 settles the closed-period part of the BUG-070 accounting policy (revision 4 Q1); the ordering inside open periods remains a recommendation awaiting approval (§16.9.5).

### 1.5 Implementation decision (revision 6)

| # | Decision | Where |
|---|---|---|
| 22 | **Implementation instruction (owner, 2026-11-22).** Implement the multi-unit / nested-packaging workflow end to end and commit it locally. Costing uses **posting order (W2)** — this answers Q1. A **void is an explicit reversal at its own posting time**; it never erases the voided document from history or recalculates later costs as if it never existed — this answers Q10 for voids. **No accounting-period engine** in this phase (P1.B's period capability is deferred; `received_on` keeps its current meaning, answering Q5a for now). **Every actual change of the stored average is audited, including receipt posting** — this answers Q3. Negative-balance replay safeguards (Decision 19) apply to every replay, which is now only a manual or batch recalculation (Q2). | §21 |

### 1.6 Earlier decisions (unchanged)

1. Historical movements and balances are never modified automatically.
2. The base-unit quantity in `inventory_movements` is the foundation of stock calculations.
3. Sealed/opened packaging state is tracked, not inferred from the total.
4. A partial-issue reversal returns quantity as loose content; nothing is resealed.
5. A full-package request requires full packages at the requested level (strict).
6. Reservations are base-unit only; no package reservations.
7. Every inventory operation protects approved reservations.
8. Stored unit costs and averages use 8 dp, including replays; historical movement costs and money totals are never rewritten.
9. A base-unit change on a product with history needs a dedicated audited conversion document.
10. One authorised user posts a conversion: permission `convert_inventory_units`, reason, preview, complete audit, atomic, no default role, owners implicit.
11. The packaging state of converted stock is selected explicitly; never assumed sealed.
12. Packaging size reuses `products.measure_amount` where technically appropriate (made concrete by Decision 1).
13. Implementation on a new independent branch, separate from the current barcode / gallery / Measure work.

---

## 2. Verified current state [Fact]

### 2.1 Repository and Measure work

* Branch `fix/product-barcodes` at `a41970d3`, stacked on `8d323504` on `main` `ca33edbb`; `origin/main` is still `ca33edbb`; neither stacked commit is in `main`.
* The Measure work is still **uncommitted** (Measure model rules in `app/models/product.rb`, migration `db/migrate/20261122090000_add_measure_amount_to_products.rb`, `config/locales/product_measures.{en,ar}.yml`, specs `spec/requests/inventory/product_measure_spec.rb`, `spec/requests/inventory/product_measure_amount_spec.rb`, `spec/system/inventory/product_measure_spec.rb`). The migration is applied to the test and Development databases only.
* `Product::UNITS_OF_MEASURE = %w[ml l fl_oz g kg gal oz lb cm ft in pieces]`; `measure_amount numeric(12,3)`, positive or NULL (check `products_measure_amount_positive`). The Measure can be changed freely today with stock on hand; the spec "changing a product's measure converts nothing" pins it.

### 2.2 Ledger, writers and cost paths

* `inventory_movements`: `quantity numeric(12,3)` (model validation `> 0`; no database check), `unit_cost numeric(12,4)`; no append-only trigger; on-hand = signed sum (`Inventory::StockLevels::SIGNED`); no stored balance.
* Writers: `GoodsReceiptPoster#post_item`, `StockIssuePoster#post_item`, `StockTransferPoster#post_item`, `AdjustmentPoster#post_item`, `DocumentVoider#call`, and **`Laundry::BatchMaterialConsumer#call`** — the only bypass (`InventoryMovement.create!` directly, no product lock, availability read before its transaction). Indirect writers all go through a poster (`ProductImporter`, `StockCountApprover` → `AdjustmentPoster`; `StockCountReopener`, `GoodsReceiptVoider` → `DocumentVoider`; confirmation services → posters).
* Average cost is written by **two algorithms** (central to BUG-070, §16):
  * `ProductCostUpdater#apply_receipt` (called by `GoodsReceiptPoster#post_item`): incremental blend at the ledger on-hand **at posting time**, in posting order, cast to the column scale at each receipt.
  * `ProductCostRecalculator#recompute!` (called after **every** `AdjustmentPoster` posting and every `DocumentVoider` void): full replay in `order(:occurred_on, :id)` (document date), excluding voided documents, seeded with `initial_cost_price`, full precision until a single cast at the end; writes no audit entry.
* Rails casts decimals in two steps (`BigDecimal(value, precision)` to significant digits, then `round(scale)`, half away from zero); PostgreSQL rounds the same way.

### 2.3 Documents, counts, purchasing

* One base `quantity` per document line; no entered unit.
* `GoodsReceiptPoster#purchase_request_quantities_valid?` locks request lines and compares the summed base quantity per request line; several receipt lines may reference one request line.
* `StockAdjustmentItem` validates `quantity_difference` `other_than: 0`; `StockAdjustment#stock_count_reason_matches_link` lets only a stock count's approval post a `stock_count` adjustment; `StockCountApprover#post_adjustment!` builds lines only for non-zero differences and posts nothing when none exist.
* `StockCountItem#counted_quantity_is_whole` forces whole counts for every product.
* Thresholds (`product_warehouse_settings.low_stock_level`, `reorder_quantity`) are base-unit.
* `ProductBarcode::BARCODE_TYPES = %w[manufacturer internal carton]`.
* No inventory endpoints in `app/controllers/api/v1/`.

### 2.4 Reservations, locks, audit

* `Inventory::StockAvailability`: available = on-hand − reserved (approved, non-voided issues); `lock_products!` = `FOR UPDATE` in id order. `StockIssueApproval` / `StockIssuePoster` check reserved under the lock; transfers, adjustments, count approval and voids check on-hand only (under the lock); laundry checks on-hand only without a lock.
* `StockTransferPoster` writes no audit entry; `StockIssuesController` and `StockTransfersController` call `DocumentVoider` without `audit: true` (adjustment voids and count reopens pass it; `GoodsReceiptVoider` writes its own entry).
* `config/initializers/schema_dumper_database_guards.rb` appends user-defined functions and triggers to `db/schema.rb`.
* **Audit plumbing (read in revision 4):** `AuditLog` `belongs_to :actor, class_name: "User"` (required) and `:business`; `auditable` polymorphic (type and id validated present). `AuditLoggable#log_audit` writes in its own savepoint and fails open (returns `nil`); `#log_audit!` raises `AuditLoggable::AuditWriteFailed` so the caller's transaction rolls back (fail-closed). `AdjustmentPoster#audit_posting` skips its entry when `created_by` is nil. The existing system-actor convention is `Payroll::AutoGenerator#system_actor` = the explicit actor, else `business.owner`. There is no inventory audit-log screen today (routes expose only `audit_failures`, and payroll has `view_payroll_audit_log`).
* **Recalculator call sites and negative balances:** `ProductCostRecalculator.new(product).recompute!` is called only from `AdjustmentPoster#call` (each product on the adjustment) and `DocumentVoider#call` (each affected product), inside their transactions. When the replay's running on-hand is not positive it skips the blend for that receipt (`if new_total.positive?`), lets the running quantity go negative without any signal, and still writes the final average with one `update!` at the end; it returns nothing to its caller.

### 2.5 Development data (read-only)

176 products (175 with a non-zero average); 2,148 movements (maximum cost scale 4; one fractional quantity); 0 approved stock issues; 435 movements dated before the day they were posted (110 products); valuation 130,063.87 SAR. Production has **not** been inspected (§17).

---

### 2.6 Dates, periods and cost snapshots (read in revision 5)

* **No accounting-period concept exists for inventory or costing.** The schema has `payroll_periods` (and their branch reviews) only; no table, column, service or route for an inventory / accounting period, a period close, a lock date or a closing snapshot (searched `app/`, `db/schema.rb`, `config/routes.rb`). Today **no period is closed**, so Decision 21 has nothing to apply to until periods exist.
* **Goods receipts carry one business date, `received_on`** (required); there is no separate supplier-invoice date or invoice number column. `GoodsReceiptPoster` writes `occurred_on: received_on`. The posting / recording time is the movement's `created_at` (and the receipt's `confirmed_at`).
* Other document dates: issues `issued_on`, transfers `transferred_on`, adjustments `adjusted_on` → movement `occurred_on`. **Void reversals and laundry consumption are dated `BusinessDay.current`** (not the original document date).
* **Issue, transfer and adjustment lines snapshot the product's current average** as `unit_cost` at posting (`item.unit_cost = item.product.average_cost_price` in `StockIssuePoster`, `StockTransferPoster`, `AdjustmentPoster`), and the movement carries it. Recalculation never rewrites these snapshots; it rewrites only `products.average_cost_price` / `last_purchase_price`.
* **Stock-value reports use the current stored average**, not a historical one (`Reports::CurrentStock`, `WarehouseSummary`, `NoMovement`, `LowStock`, `BranchComparison` read `average_cost_price`). There is no as-at-date valuation; a recalculation therefore changes these reports' figures for every date range at once.
* `ProductCostRecalculator` excludes every voided document from the **whole** history, so voiding an old receipt re-costs everything after its date.

## 3. Business requirements and worked examples

### 3.1 Requirements

* Separate purchase, receiving, base, packaging, issue, transfer and stocktake units, on one ledger.
* Nested packaging (carton → box → piece; pallet → carton → box → piece) and divisible content (bottle → ml; bag → g).
* Composite quantities on one line ("1 carton + 6 boxes", "2 bottles + 100 ml").
* Partial and mixed-unit receipts against a purchase request; remaining quantity in the purchase unit.
* Opening a package changes packaging state only — never total stock, never cost.

### 3.2 Arithmetic used throughout

* Razor blades (1 carton = 12 boxes, 1 box = 10 pcs): 1 carton → issue 3 boxes → **9 boxes = 90** → issue 15 pcs → **7 boxes + 5 pcs = 75** (the original "8 boxes + 5 = 85" was inconsistent).
* 1 carton → issue 15 pcs → **10 boxes + 5 pcs = 105**.
* Shampoo (355 ml): 12 sealed (4,260) → 100 ml → **11 sealed + 255 ml (4,160)** → 200 ml → **11 sealed + 55 ml (3,960)**.

Full step tables: Appendix A.

---

## 4. Packaging hierarchy [Proposal within Decisions 1–3, 14]

### 4.1 `product_packaging_levels`

| Column | Rule |
|---|---|
| `business_id`, `product_id` | required; same business |
| `position` | 1 = innermost … 4 = outermost; check `position BETWEEN 1 AND 4` |
| `package_unit` | translatable code (bottle, can, jar, tube, bag, sachet, box, pack, carton, case, pallet); EN + AR |
| `contains_quantity` | level 1: base units per package (`> 0`, 3 dp; whole when the base unit is `pieces`); levels ≥ 2: a whole count of the level below (`> 0`, check `contains_quantity = trunc(contains_quantity)`) |
| `base_quantity` | product of the chain to base units; stored; immutable |
| `status` | `active` / `retired`, `retired_at`, `retired_by_id` |
| `created_by_id`, timestamps | — |

Constraints: partial unique indexes `(product_id, position)` and `(product_id, package_unit)` WHERE `status = 'active'` (together with the position check these make a fifth active level impossible); unique `(id, product_id)` for the composite foreign key in §5; no DELETE (trigger refuses; levels are retired, never deleted).

### 4.2 Shape

Linear chain only — the order is the relationship, so circular or inconsistent conversions are impossible by construction. No alternative packaging in V1. `pieces` is indivisible; every other Measure is divisible to 3 dp. Package counts are whole.

### 4.3 Adding, retiring, replacing (only through `Configurator`, audited, product row locked)

| Change | Allowed when |
|---|---|
| Add a new outermost level | fewer than 4 active levels |
| Define / change levels on a product with no packaging entries | always |
| Change `contains_quantity` of a level referenced by any packaging entry | never — replace |
| Replace a referenced level | create the new definition, reclassify by Stocktake (Decision 4), then retire the old level |
| Retire a level | its free balance is 0 in every warehouse and no open document line references it; remaining active positions stay contiguous from 1 |
| Insert between levels | only if no level above the insertion point is referenced |

Configuring packaging never changes stock: existing stock stays loose until an opening packaging count (§8).

### 4.4 Configurator responsibilities

Single application path for levels and for `measure_amount` on packaged products: locks the product row, validates the chain (≤ 4, contiguity, divisibility, immutability of referenced levels), writes levels and `measure_amount` in one transaction, forces the deferred trigger check before returning (§4.5), writes an audit entry (`packaging_configured` / `packaging_level_retired`, before/after).

### 4.5 `measure_amount` synchronisation — Configurator + database trigger (Decisions 1, 14)

Rule: when a product has an active level at position 1, `products.measure_amount` must equal that level's `contains_quantity` (and is not NULL). A product without active levels is unconstrained (`measure_amount` keeps its current, optional, descriptive meaning).

Proposed trigger (future schema change, not created):

* **Function** `inventory_check_measure_amount(product_id)` — raises when the rule is violated, or when active positions are not contiguous from 1; never writes.
* **Constraint triggers, `DEFERRABLE INITIALLY DEFERRED`, `FOR EACH ROW`:**
  * on `product_packaging_levels` `AFTER INSERT OR UPDATE` (covers creating level 1, changing an unreferenced level 1, retiring, replacing);
  * on `products` `AFTER UPDATE OF measure_amount` (covers direct writes that bypass Configurator);
  * plus a plain `BEFORE DELETE` trigger on `product_packaging_levels` refusing deletes.
* **Why deferred:** Configurator writes the level and the product in one transaction in whichever order is convenient; the check runs at commit on the final state, so there is no intermediate false failure and no write-ordering coupling.
* **Insert:** a new level 1 is checked against `measure_amount` at commit. **Update:** only unreferenced levels may change (Configurator); the trigger checks the resulting pair. **Retirement:** retiring level 1 requires retiring every level (back to no packaging) or replacing it in the same transaction; otherwise contiguity fails. **Replacement:** retire old level 1 → insert new level 1 → update `measure_amount`, one transaction, checked at commit. (Retire before insert, because the partial unique index on active positions is not deferrable.)
* **Products without levels:** the trigger returns immediately — no behaviour change for existing products.
* **Four-level maximum:** enforced by the position check and the partial unique index; the trigger additionally rejects gaps, so active positions are always exactly 1..n with n ≤ 4.
* **No conflict with Configurator:** the trigger only validates; Configurator always writes a consistent pair; the `Product` model carries the same rule as a validation for friendly form errors.
* **Error reporting:** `RAISE EXCEPTION ... USING ERRCODE = 'check_violation'` with a stable constraint name (`products_measure_amount_matches_innermost_level`), surfacing as `ActiveRecord::StatementInvalid` (`PG::CheckViolation`). Configurator issues `SET CONSTRAINTS ... IMMEDIATE` before leaving its transaction so the error surfaces inside the service (not at an outer commit) and maps it to a failed `Result` with an EN + AR message.
* **Schema persistence:** dumped into `db/schema.rb` by `config/initializers/schema_dumper_database_guards.rb` (keep that initializer).

### 4.6 Base-unit lock (Decision 2)

`products.unit_of_measure` changes only while the product has no inventory movements; afterwards the form disables it and the model refuses it, except when written by `Inventory::UnitConversionPoster`. P3 updates the Measure work: `Product` validation, `ProductsController#update` error path, `inventory/products/_form.html.erb`, `ProductImporter` (Measure for existing products with movements → skip reason, EN + AR), and rewrites the spec "changing a product's measure converts nothing" to "refused once movements exist; allowed before".

---

## 5. Inventory and packaging ledgers [Proposal]

* **`inventory_movements` stays the source of truth** for total stock and cost. New nullable `unit_of_measure` on new rows (NULL on history = the base unit before the product's first conversion). New reasons only in P6.
* **New append-only `inventory_packaging_entries`:** `business_id`, `product_id`, `warehouse_id`, `packaging_level_id` (composite FK `(packaging_level_id, product_id)` → `product_packaging_levels (id, product_id)`), `package_delta` (signed integer, ≠ 0), `kind`, `inventory_movement_id` (nullable), `source_type` / `source_id`, `occurred_on`, `created_at`. Indexes `(product_id, warehouse_id, packaging_level_id)`, `(source_type, source_id)`, `(inventory_movement_id)`. UPDATE/DELETE refused by trigger.

| Kind | Meaning | Reversed by |
|---|---|---|
| `moved` | packages that physically entered/left with the movement | the document's void (negated) |
| `breakdown` | an opened parent (−) and the children it releases (+) | never (no resealing) |
| `count_correction` | a stocktake packaging difference | reopening the count |
| `conversion` | old-level balances retired and the selected new state | voiding the conversion |

* **Derived balances** (one grouped query, `Inventory::Packaging::Balances`): `free[L] = SUM(package_delta)`; `total = SUM(signed quantity)`; `loose = total − Σ free[L] × base_quantity[L]`.
* **Invariants**, checked under the product lock before writing: every `free[L] ≥ 0`; `loose ≥ 0`; loose and base quantities whole for `pieces`; opening never changes `total`; entries reference only active levels of the same product.
* **No quantity-zero movements** for packaging-only changes; **no backfill**; products and movements without entries are all-loose.

---

## 6. Packaging planner [Proposal]

`Inventory::Packaging::Planner` — pure (no database). Input: active structure, the warehouse balance (`free[1..N]`, `loose`, `total`), a request of components `{level: L, count: n}` (strict) or `{base: q}`. Output: a plan (entries with kind, level, delta; movement base quantity; resulting balance) or a refusal (`insufficient_stock`, `insufficient_packages`, `indivisible_quantity`, `unknown_level`, `retired_level`) with the available figures.

```
plan(request): components largest unit first, base last
take_base(q):        refuse :insufficient_stock if q > total remaining
                     if loose < q: m = ceil((q − loose) / base_quantity[1]); ensure_free(1, m); free[1] −= m   # breakdown
                     loose −= q
take_packages(L, n): ensure_free(L, n); free[L] −= n                                                            # moved
ensure_free(L, m):   return if free[L] ≥ m
                     refuse :insufficient_packages if L == N                                                    # strict
                     p = ceil((m − free[L]) / contains_quantity[L+1]); ensure_free(L+1, p)
                     free[L+1] −= p; free[L] += p × contains_quantity[L+1]                                      # breakdown
```

* **Minimum opening:** each level opens the ceiling of its own deficit divided by its content; because the chain is divisible (whole counts per level), opening smaller packages first always leaves less excess, so loose-first then smallest-first is optimal in packages opened and content unsealed.
* **Strict rule:** package components may open higher levels (a box inside a sealed carton is a full box) but never use loose content or lower levels; the outermost level is satisfied only by free packages of that level.
* **Preservation:** total changes only by the movement quantity; breakdown entries are base-neutral; the planner carries no money.

---

## 7. Workflows [Proposal]

Every workflow: lock products first, read fresh balances / reservations / average under the lock, plan, check reservations (§10), write movement + entries in one transaction, audit.

### 7.1 Purchase requests (Decisions 7, 15)

* Line: purchase unit (a level or the base unit), entered quantity, `entered_unit_price` per purchase unit (`numeric(16,8)`) and `price_level_id`; `quantity` = base total (canonical); `unit_price` = base-unit price (8 dp); `total_cost = round(entered_quantity × entered_unit_price, 4)`.
* Remaining = ordered base − received base (`PurchaseRequestItem#remaining_quantity`), always computed and validated in base units. Display: remaining ÷ base_quantity(purchase unit), **truncated (rounded toward zero)** to at most 3 dp, trailing zeros removed, with the exact breakdown / base equivalent whenever the 3-dp figure is not exact. Truncation never overstates what may still be received; the over-receipt guard never uses the display figure.

| Ordered | Received | Remaining (base) | Displayed |
|---|---|---|---|
| 2 cartons (240 pcs) | 1 carton + 6 boxes (180) | 60 | **0.5 carton** (6 boxes) |
| 2 cartons (240) | 1 carton + 6 boxes + 3 pcs (183) | 57 | **0.475 carton** (5 boxes + 7 pcs · 57 pcs) |
| 1 carton (120) | 7 pcs (7) | 113 | **0.941 carton** (11 boxes + 3 pcs · 113 pcs) — exact 0.941666…, truncated |
| 3 boxes (30) | 1 box + 1 pc (11) | 19 | **1.9 box** (1 box + 9 pcs) |
| 10 bottles (3,550 ml) | 9 bottles + 200 ml (3,395) | 155 ml | **0.436 bottle** (155 ml) — exact 0.43662…, truncated |
| 3 bags (75,000 g) | 3 bags | 0 | received in full |

### 7.2 Goods receipts (partial, mixed-unit)

Composite lines; `moved` IN entries per level; base components arrive loose; over-receipt guard on summed base quantity under the request-line locks (unchanged in substance); receipt cost §11.

### 7.3 Stock issues

Package components strict, base components loose-first. Approval: non-blocking packaging warning; posting authoritative (§10.4).

### 7.4 Transfers

Source follows the issue rules; destination receives the same `moved` packages; base components arrive **loose** (never sealed); equal base quantities; one transaction; audited (BUG-074, P2).

### 7.5 Adjustments (non-stocktake)

Increases at any level (`moved` IN or loose); decreases follow the issue rules. **No reclassification, no repackaging reason, no zero-difference lines** (Decision 4).

### 7.6 Stocktake — §8. 7.7 Laundry: base-unit take via the planner, locked, reservation-checked inside the transaction (BUG-073 in P2, planner in P4). 7.8 Voids — §9. 7.9 Conversion — §14.

---

## 8. Stocktake-only repackaging and zero-quantity packaging corrections (Decision 4) [Proposal]

### 8.1 Entry and baseline

Per product: full packages per level counted **outside** larger packages + loose content; the total is computed (`Inventory::Packaging::QuantityEntry`). At entry the recorder captures `system_quantity` and the per-level `system` breakdown (decision D2 extended). Package counts whole; loose whole for `pieces`, 3 dp otherwise (`StockCountItem#counted_quantity_is_whole` → whole for indivisible base units only). A product whose structure changes during an open count must be re-baselined before approval.

### 8.2 Classification at approval (`StockCountApprover`)

| Line case | Base difference | Level differences | Result |
|---|---|---|---|
| No difference | 0 | none | **no-op** (no line, no entry — today's behaviour) |
| Quantity only | ≠ 0 | none | adjustment line with the difference → one movement (today's behaviour) |
| Packaging only | 0 | some | adjustment line with `quantity_difference = 0` + breakdown → **no movement**; `count_correction` entries only |
| Combined | ≠ 0 | some | adjustment line with the difference → one movement + `count_correction` entries |

If every line is a no-op the count is approved with no adjustment, exactly as today. Otherwise one stock-count adjustment is posted through `AdjustmentPoster`.

### 8.3 Narrow exception to the zero-difference rule

* `StockAdjustmentItem` allows `quantity_difference = 0` **only when** its adjustment has `reason = stock_count`, a `stock_count_id`, and the line carries at least one non-zero level difference. Every other zero line stays invalid (`other_than: 0` unchanged for manual adjustments, imports and opening balances).
* `StockAdjustment#stock_count_reason_matches_link` already guarantees only a count's approval can create a `stock_count` adjustment, so the exception cannot be reached from the manual adjustment form.
* `AdjustmentPoster#post_item` writes no movement for a zero line; `Packaging::EntryWriter` writes its `count_correction` entries with `inventory_movement_id` NULL and the adjustment as source. The cost recalculation is not triggered by a packaging-only adjustment (no cost-relevant movement).

### 8.4 Authorisation, audit, reopening

* Authorisation unchanged: `post_stock_counts` with the existing segregation of duties (decision D1); no new permission.
* Audit: the approval audit metadata lists, per line, `quantity_difference` and the level differences (`{level, system, counted}`); the adjustment's `post` audit includes the same.
* Reopening (`StockCountReopener` → `DocumentVoider` with `stock_count_reopen: true`): reverses the movement(s) as today and negates the `count_correction` entries; checks that every resulting `free[L] ≥ 0` and `loose ≥ 0` under the product lock (refused with an explanation otherwise) and checks reservations for any base removal (§10).

### 8.5 Required regression tests

* Manual adjustment with a zero line → invalid (form and service).
* Product import opening balance with a zero line → invalid.
* `stock_count` adjustment with a zero line **without** a level difference → invalid.
* Count with all no-difference lines → approved, no adjustment, no entries.
* Packaging-only, quantity-only and combined lines → exactly the rows in Appendix A; reopen restores the prior balance.

---

## 9. Voids and reversals (Decision 5; Earlier 4) [Proposal]

* A void mirrors the base movement(s) at the **original unit cost** and negates the document's `moved` entries (and `count_correction` / `conversion` entries for count reopen / conversion void). `breakdown` entries are never reversed.
* **Inflow void after opening:** for each `moved` IN entry, remove as packages as many as are still free at that level; remove the shortfall as base quantity through `take_base` (loose first, minimum opening). The base total removed equals the original document; reservations are checked on the removal (§10); if on-hand is insufficient the void is refused as today (`void_would_oversell`).
* **Preview:** per product and warehouse — packages restored, base removed from opened content, packages to be opened, resulting balance. At confirmation the plan is recomputed under the locks; if it differs from the preview, confirmation is refused and the new preview shown.
* Example (carton = 12 boxes = 120 pcs): R1 receipt 5 cartons (600) → issue 15 boxes (breakdown carton −2, box +24; moved box −15) → 3 cartons + 9 boxes (450) → R2 receipt 20 boxes → 3 cartons + 29 boxes (650) → void R1: moved carton −3 (360) + 240 pcs as base (breakdown box −24) → **0 cartons + 5 boxes (50)**. Preview: "3 cartons restored, 240 pcs removed from 24 opened boxes".

---

## 10. Reservations and concurrency

### 10.1 Model (Earlier 6, 7)

Base-unit reservations only (a 3-box line reserves 30 pcs).

### 10.2 Invariant [Proposal]

For every removal from warehouse W of product P not consuming its own reservation: `on_hand(W,P) − removal ≥ reserved(W,P)`, checked under the product lock by `StockAvailability.removal_shortfalls(warehouse_id:, removals:, excluding_issue_id: nil)`; refusals name the approved issues holding the stock (EN + AR).

### 10.3 Affected operations

| Operation | Today | Change (phase) |
|---|---|---|
| Issue approval / posting | on-hand + reserved, locked | none; posting adds strict package check (P4) |
| Issue edit / cancellation | releases only | none |
| Transfer source | on-hand only | reserved check (P2) |
| Adjustment decrease | on-hand only | reserved check (P2) |
| Count approval (base decrease) | on-hand only | reserved check; refusal lists conflicting issues (P2) |
| Count reopen / inflow void | on-hand only | reserved check (P2) |
| Laundry | on-hand only, unlocked | lock + check inside the transaction (P2, BUG-073) |
| Packaging-only changes | — | never conflict (base unchanged) |
| Conversion | — | precondition: no reservations (P6) |

### 10.4 Approval warning and posting (Decision 6)

`StockIssueApproval` keeps the blocking base check; runs the planner read-only; if packages are short it shows a non-blocking warning, records it in the approval audit metadata, approves and reserves. `StockIssuePoster` re-plans strictly under the lock; on failure the issue stays approved and reserved and the message states what is available ("Needs 3 full boxes; 1 full box, 0 full cartons and 25 pcs loose available — edit the line to pieces or cancel the issue"). No silent substitution.

### 10.5 Locks and transactions

Document row lock (where the workflow has one) → `lock_products!` (`FOR UPDATE`, id order) → read movements, entries, reservations, average from rows reloaded under the lock → plan → write → audit, one transaction. Reservations only grow under the same product lock and only shrink elsewhere, so a check under the lock cannot go stale. Receipts take the product lock (BUG-071, P1).

### 10.6 Concurrency tests (two real connections)

Two receipts of the same product (both blend); issue posting vs transfer; laundry vs approval; count approval vs approval; void vs posting; two issues opening the same carton.

---

## 11. Costing (Earlier 8) [Proposal for mechanics]

* One product-level moving average per base unit, stored to 8 dp; money totals 4 dp (`numeric(14,4)`); money display 2 dp.
* Receipt price unit: `line total = round(entered_unit_price × base_qty ÷ base_quantity[price unit], 4)`; `base unit cost = round(total ÷ base_qty, 8)`; the movement carries the base cost; averages blend at 8 dp through one shared `Inventory::CostPrecision.blend`, used by both `ProductCostUpdater` and `ProductCostRecalculator` (P1).
* Opening packages has no cost effect (entries carry no money; no movement).
* Issues, transfers, adjustments, laundry: base quantity × current average; totals 4 dp. Reversals mirror the original unit cost. Conversion: average ÷ factor.
* Verified figures: carton 120.00 → 1.00000000/pc, 15 pcs = 15.0000; 12 bottles at 25.00 → 0.07042254/ml (4-dp storage loses 0.0960 SAR on 4,260 ml), 100 ml = 7.0423; three bottle receipts (25 / 27 / 26.50) value exactly 1,098.0000 at 8 dp vs 1,097.3760 at 4 dp; pallet 4,800 pcs at 9,999 → 2.08312500; bag 25,000 g at 47.30 → 0.00189200/g. Residual from 8-dp storage ≤ 0.5 × 10⁻⁸ SAR per base unit.
* Nested packaging adds no precision requirement beyond P1.
* **Which average a replay should produce** is governed for closed periods by Decision 21 and inside open periods by the pending choice in §16.9.5. §11.1 and §11.2 apply whatever is chosen.
* Today no average change is audited [Fact: Development has no `AuditLog` row for product 346, whose average was changed by a replay]. Decision 17 makes the audit mandatory (§11.1).

### 11.1 Audit of recalculated average-cost changes (Decision 17) [Proposal for mechanics]

**What is audited.** Every `ProductCostRecalculator` run that changes `products.average_cost_price` (compared at the stored scale: `new.round(scale) != stored`) writes exactly one entry for that product. A change to `last_purchase_price` alone is recorded in the same entry when it accompanies an average change, and on its own entry otherwise (same rules). An unchanged value writes **no** entry — the existing audit architecture has no no-change convention.

| Field | Content |
|---|---|
| `auditable` | the `Product` |
| `action` | `average_cost_recalculated` |
| `changes_json` | `{ "average_cost_price": [previous, new], "last_purchase_price": [previous, new] }` (only changed keys; BigDecimal as fixed-point strings) |
| `metadata.trigger` | `adjustment_posted` · `document_voided` (incl. stock-count reopen, `metadata.stock_count_reopen: true`) · `manual_recalculation` · `batch_replay` · `backdated_receipt_posted` and `rollout_replay` (only if §16.9 needs them) — closed list; an unknown trigger is refused, so the source is always identified |
| `metadata.source` | `{ type, id, number }` of the triggering document (adjustment, issue, transfer, receipt, count); `null` only for `manual_recalculation` / `batch_replay` |
| `metadata.operation_ref` | the triggering document's audit context (its type/id) for in-posting runs; a UUID `recalculation_run_id` for manual and batch runs (one per run, shared by all products of the run) |
| `metadata.replay` | ordering used (today `occurred_on, id`), movements replayed, voided documents excluded, algorithm version |
| `actor` | the triggering operation's user (adjustment `created_by` / poster's user; voider's `user`); for manual runs the requesting user; for jobs/console batch runs an explicit actor argument, else `business.owner` (the `Payroll::AutoGenerator#system_actor` convention), with `metadata.system: true` so automated runs are distinguishable |
| `business`, `created_at` | from the actor; the database timestamp of the entry |

**Transaction and failure handling.**
* The entry is written with **`log_audit!` (fail-closed) in the same transaction as the `update!`**, after it. The stored average is an in-place overwrite whose audit entry is the only record of the previous value — the CLAUDE.md criterion for `log_audit!`. If the entry cannot be written, `AuditWriteFailed` rolls back the average **and** the triggering posting/void, which returns a failed `Result` (the poster/voider already map `ActiveRecord::ActiveRecordError`). Consequence to accept at approval: an audit-write failure blocks the adjustment or void instead of letting it through unaudited.
* A failed recalculation (exception, negative-balance stop per §11.2) writes no success entry: the entry is created only after a successful `update!`, and any rollback removes both.
* Existing `AuditLog` rows are never updated or deleted; each change is a new row.
* The adjustment's own `post` entry is still skipped when `created_by` is nil (today's behaviour, unchanged); the recalculation entry then uses the system actor above so the average change is never unaudited.
* Not used: `Audit::DurableEntry` (it refuses to run inside a transaction, and this write must be atomic with the recalculation).

**Idempotency.** The recalculation runs under the product lock (`lock_products!`); a second run on the same history finds the stored value already equal and writes nothing. A repeated void is stopped by the existing document row lock and `already_voided` guard, so its recalculation and entry happen once. A batch run repeated with the same `recalculation_run_id` writes nothing for products already at the replayed value.

**Authorisation.** Entries are written only by services (no endpoint creates them). Running a manual or batch recalculation needs its own narrow permission (to be named at P1 approval; owners implicit; no default role) and is refused otherwise. Any future screen that shows these entries uses `view_inventory` plus the warehouse scope; no such screen is in scope.

**Tests (P1).** Entry on change with every field; no entry when unchanged; one entry per product on a multi-product adjustment; void and count-reopen triggers; system-actor run (`metadata.system`); unknown trigger refused; audit-write failure (stubbed `AuditLog.create!`) rolls back average and posting and returns a failed Result; recalculation exception leaves no entry; double void → one entry; concurrent recalculations of one product (two connections) → one change, one entry; manual run refused without the permission; unit costs in the entry rendered per §12.

**Scope note.** Decision 17 covers recalculations. The incremental receipt update (`ProductCostUpdater`) also changes the stored average; recording it the same way is recommended but is outside the decision [Unresolved Q3].

### 11.2 Negative balance during replay: stop and diagnose (Decision 19) [Proposal for mechanics]

**Per-product isolation.** A replay reads only one product's movements and writes only that product's row, so each product is an independent unit:
* **In-posting runs** (`AdjustmentPoster`, `DocumentVoider`): each product is replayed separately under the product lock already held by the poster; a stopped product is simply not written, and the other products continue. This is safe because no product's result depends on another's.
* **Manual / batch runs:** each product in its own transaction with its own `lock_products!`, so one product's stop or error cannot affect another's commit. If the run is invoked inside an enclosing transaction (per-product commits impossible), it refuses to start and reports the limitation (Decision 19.8) — the whole operation stops, nothing is written.

**The stop.** The replay computes in memory and writes once at the end (today's structure). If the running on-hand becomes negative at any movement:
1. stop processing that product;
2. do not call `update!` — the stored average and last purchase price stay exactly as they were (no partial result exists to write);
3. write no `average_cost_recalculated` entry;
4. return a `stopped` outcome with the diagnostic.

**Diagnostic report** (one per stopped product):

| Field | Content |
|---|---|
| product | id, SKU, name |
| offending movement | movement id, reason, direction, quantity, `occurred_on`, `created_at`, source document (type, id, number, status) |
| replay ordering | the ordering used (`occurred_on, id`) and that voided documents were excluded |
| balance | running on-hand immediately before and after the offending movement |
| context | the preceding receipts / documents in replay order and the posting-order on-hand at the same movement |
| likely cause | **chronology** — the posting-order balance at that movement was never negative (back-dating moved an outflow ahead of its inflow); **historical data** — negative in posting order too (e.g. stock removed before any recorded inflow or opening balance); **voided-document exclusion** — negative only because an inflow's document was voided after later outflows; **unresolved** — none of these |

Where it goes: in-posting runs return it in the poster's / voider's `Result` and record it as an audit entry `average_cost_recalculation_stopped` (diagnostic fields in metadata, no `changes_json`, same transaction, so it cannot claim success); manual and batch runs return the report for review (and the same per-product entries). The triggering adjustment or void still posts, because its stock movements are valid on their own; only the average is left unchanged. [Unresolved Q2: confirm this applies to the automatic recalculation, not only to a BUG-070 batch replay.]

**Never:** insert artificial opening balances, skip movements, reorder records silently, clamp the balance to zero, or modify historical records to make the replay succeed. Any correction of a stopped product is a separate investigation with explicit approval.

**Known population [Fact, revision 3]:** 7 Development products reach a negative balance under the current date-order replay; with §11.2 in place their averages stop changing on adjustments and voids until their history is reviewed. Production count: §17.

**Tests (P1).** Negative at first / middle / last movement → no write, no success entry, diagnostic fields exact; multi-product adjustment with one stopped product → others written and audited; batch run with per-product transactions continues after a stop; batch run inside an enclosing transaction refuses to start; each likely-cause classification; no movement, count or document row changed by any run.

---

## 12. Formatting and display policy (Decisions 11, 15, 18) [Proposal for helpers]

Display formatting never changes stored values, accounting calculations or money rounding.

**Unit costs (Decisions 11, 18):**

| Stored value | Display |
|---|---|
| `25.00000000` | `25` |
| `25.50000000` | `25.5` |
| `0.70000000` | `0.7` |
| `0.70400000` | `0.704` |
| `0.00000125` | `0.00000125` |

Rule: up to 8 dp where needed, trailing zeros (and a trailing decimal point) removed, never scientific notation; applied on screens, reports, exports and audit displays (including the `average_cost_recalculated` entries of §11.1).

| Value | Stored | Displayed |
|---|---|---|
| Unit costs (movement, item, average, last purchase, initial cost, request unit price) | `numeric(16,8)` (after P1) | the unit-cost rule above |
| Money totals | `numeric(14,4)` | 2 dp via `format_currency` (unchanged) |
| Purchase remaining | base `numeric(12,3)` | purchase unit, up to 3 dp, truncated toward zero, trailing zeros removed, exact breakdown / base equivalent when not exact (§7.1) |
| Inventory quantities | base `numeric(12,3)` | unchanged: `pieces` whole; divisible Measures up to 3 dp; packaged stock as "1 carton · 2 boxes · 5 pcs (145 pcs)" |
| Exports (CSV) | — | unit costs as fixed-point text with the same rule; money totals `round(2)`; quantities fixed-point (BUG-072) |

One helper per value type (`format_unit_cost`, `format_purchase_remaining`, existing quantity helpers) — BigDecimal-based, never `to_f` — used by screens, reports and exports alike.

---

## 13. Historical compatibility (Earlier 1)

No backfill. Products without packaging levels: all-loose and byte-for-byte unchanged (regression harness). Existing movements, counts and open documents keep their meaning (open documents created before packaging are base-unit lines). NULL `unit_of_measure` = the base unit before the first conversion. Historical movement costs and totals are never rewritten.

---

## 14. Unit Conversion document (Earlier 9–11) [Proposal for mechanics]

* Permission `convert_inventory_units` in the `inventory` group of `OrganizationAccess::PermissionRole::PERMISSION_GROUPS`, depending on `manage_inventory` and `manage_products` (`PERMISSION_DEPENDENCIES`), absent from `DEFAULT_PERMISSIONS_BY_ROLE_TYPE`; owners have it implicitly through `ApplicationPolicy`; `InventoryUnitConversionPolicy` uses `can?(:convert_inventory_units)`.
* `inventory_unit_conversions` (product, from/to unit, factor, new packaging definition, reason, snapshot of the old configuration incl. average and thresholds, status `posted`/`voided`, actor/time) + per-warehouse lines.
* Preview; reason required; atomic posting; `log_audit!` (fail-closed) on document and product.
* Preconditions under the product lock: no open documents (`Inventory::TrackingDependencies` blockers plus pending-approval receipts and in-progress laundry batches), hence no reservations; no negative stock; exact divisibility in every warehouse.
* Posting: per warehouse `unit_conversion_out` + `unit_conversion_in` (cost-bearing in replay); old levels' balances negated and retired (`conversion` entries); new levels created; packaging state **chosen per warehouse** ("all loose" or a breakdown summing to the converted total); `unit_of_measure` / `measure_amount` through the Configurator path (consistent with the trigger); thresholds × factor (3 dp).
* Reversal: void only when nothing for the product postdates the conversion (mirror rows, negated `conversion` entries, snapshot restored, audited); otherwise a reverse conversion document (exact divisibility back).
* Adding packaging without changing the base unit is not a conversion.

---

## 15. BUG-070 – BUG-074 audit register (Decisions 8, 12, 13, 17, 19, 20)

### 15.1 Source and status

`docs/quality/deferred-bugs.md` ends at **BUG-069**. None of BUG-070 … BUG-074 is registered in that file, in any other repository file, or on any local or remote branch (searched 2026-11-22). Their only source is the planning reports (BUG-070 – 073: Phase 2 final report; BUG-074: Phase 3 report). Every statement below was re-verified against the current code; the BUG-070 statement was refined by the investigation in §16. **Status of all five: Proposed — not registered — not fixed.**

### 15.2 Register

| Bug | Verified definition | Current code behaviour | Root cause | Overlap / related | Required fix | Phase | Dependencies | Tests | Blocks |
|---|---|---|---|---|---|---|---|---|---|
| **BUG-070** | A product's stored average depends on which of two cost algorithms last wrote it; a full recalculation after a back-dated document produces a different average from the incremental receipt update | Incremental updater: posting order, weight = ledger on-hand at posting. Recalculator: document-date order, voided documents excluded, after every adjustment and void | Two writers with different ordering semantics (§16) — **mechanism explained; closed-period policy decided (Decision 21); open-period order not yet approved** | Interacts with BUG-071 (same writer) and P1 rounding (`blend`) | **Not yet approved.** Closed-period policy decided (Decision 21, §16.9); recommended: accounting periods with closing snapshots, effective costing date E3, open-period order W2 — awaiting approval | P1.B | §16.7; accounting periods (§16.9.4) | replay equivalence for the chosen semantics; back-dated and voided histories; Development path simulation reproduces stored values (§16.4); §19.3 items 30 – 34 | P1.B completion; nothing else |
| **BUG-071** | Concurrent receipt postings can lose an average-cost update; transfer and adjustment posters value stock before locking | `GoodsReceiptPoster` never calls `lock_products!`; reads `average_cost_price` / `current_stock` from preloaded, unlocked products. `StockTransferPoster#call` and `AdjustmentPoster#call` run `value_items` before their transactions; `StockIssuePoster` values inside the lock from products loaded earlier | Missing product lock and stale reads | BUG-070 (same cost path) | `lock_products!` (id order) at the start of receipt posting; read average and on-hand from rows reloaded under the lock in every poster | P1 | none | two-connection receipts of one product both blend; valuation read after lock per poster; no deadlock with request-line locks (lock order documented) | P1 completion |
| **BUG-072** | CSV exports write BigDecimal values in scientific notation | `Inventory::Reports::MovementsExport#values` puts BigDecimals (`row.unit_cost.to_d`, quantities) into `CSV.generate` → `0.704e-1`; `Finance::Reports::ExpenseDetailsCsvExporter#row` writes BigDecimal amounts / unit costs unformatted | No fixed-point formatting | Decision 11 formatting policy | Shared fixed-point formatting (§12) in both exporters; XLSX cell types verified | P1 | none | CSV text for `0.0704`, `0.07042254`, `0.00000125`, `299.904`; XLSX numeric cells | none |
| **BUG-073** | Laundry consumption reads availability without a lock and outside its transaction | `Laundry::BatchMaterialConsumer#call` reads `product.stock_in(@warehouse)` before `ActiveRecord::Base.transaction`; never calls `lock_products!`; the only ledger writer outside the posting services | Missing lock / transaction boundary | Registered **BUG-065** (warehouse scope — distinct); P2 reservation check | Move the check inside the transaction after `lock_products!`; add the reserved check (P2); route through the planner (P4) | P2 (foundation), P4 (packaging) | none for P2 | two-connection laundry vs approval / posting; reservation refusal; rollback leaves no movement or consumption row | P4 packaging integration |
| **BUG-074** | Stock transfer posting writes no audit entry; voids of stock issues and stock transfers write none | `StockTransferPoster` has no `log_audit`; `StockIssuesController` and `StockTransfersController` call `DocumentVoider.new(...)` without `audit: true` | Missing audit calls | CLAUDE.md audit-first rule; `DocumentVoider` already supports `audit: true` | Audit transfer posting inside its transaction (`post`, lines, warehouses); issue and transfer voids audited (`void`, reason, reversal lines) — moved into the service layer so every caller is covered; one entry per successful operation; none on failure (rolled back with the transaction); idempotency: the existing row lock + `already_voided` guard prevents a second void and second entry | **P2, before P4** (Decision 13) | none | entry on successful post / void; no entry when posting or void fails; rollback removes both rows and entry; double-click void → one entry; audit-write failure behaviour per BUG-003 (savepoint `log_audit`) documented | P4 |

**Revision 4 additions to the register (not new defects):** BUG-070's fix, whatever option is chosen, must satisfy §11.1 (audit every changed average) and §11.2 (negative-balance stop and diagnostic); its acceptance therefore includes the §11.1 and §11.2 tests. BUG-071's lock is also the lock under which §11.1 guarantees one entry per change.

### 15.3 Proposed severities (Decision 20) [Proposed severity — awaiting user approval]

**Conventions used [Fact: `docs/quality/deferred-bugs.md`].** The register has no formal severity scale; its entries use **Low**, **Low–Medium**, **Medium**, **High** and **High — critical (reason)**, each followed by a parenthetical impact. **Critical** is tied to the register's policy (security, unauthorised access, financial / payroll corruption, irreversible data loss, integrity failures affecting the current task) and means *Escalated*: fixed immediately, not deferred. Evidence levels are *Confirmed* (test, reproduction or unambiguous code), *Suspected* (code-evident, not reproduced) and *Improvement*. Comparable precedents: BUG-017 **High** (confirmed duplicated stock/cost reversal under concurrency); BUG-015 / BUG-016 / BUG-053 **Medium** (status or cost integrity races; BUG-053 only suspected); BUG-061 **Medium (traceability)** and BUG-044 **Low–Medium** (missing audit entries); BUG-065 **Medium** (laundry consumption path); display-only defects **Low**. The mapping below follows these precedents; none of the five is proposed as critical / Escalated, because none corrupts the ledger, loses data irreversibly or crosses an access boundary — the proposed phase slots handle them.

| Bug | Proposed severity | Evidence | Impact | Reasoning | Phase | Blocks |
|---|---|---|---|---|---|---|
| **BUG-070** | **Medium** (valuation drift; unaudited average changes) — re-assess as **High** if the Production profile (§17) shows a material valuation impact | Confirmed (Development read-only reproduction: product 346; path simulation 154 / 154) | Stored averages, and therefore the cost of every later issue, transfer, adjustment and laundry consumption, depend on which algorithm wrote last; Development: 18 products / 104.57 SAR under date order, 1 product / +2.51 SAR under posting order; changes are unaudited | Financial and auditability impact (audit-first rule), but the ledger quantities and historical movement costs are intact and the amounts are small on Development — the BUG-015 / BUG-053 level rather than BUG-017; the Production magnitude is unknown, hence the explicit re-assessment trigger | P1.B (fix after approval of §16.9) | P1.B completion |
| **BUG-071** | **Medium** (cost integrity under concurrency) | Suspected (code: no `lock_products!` in `GoodsReceiptPoster`; valuation before locking in transfer and adjustment posters); not reproduced | Two receipts of one product posted together can lose one blend; a transfer or adjustment can be valued with a stale average | Same class as BUG-053 (suspected race, Medium) and BUG-015 / 016 (Medium); not High because it is unreproduced and needs simultaneous postings of the same product | P1 | P1 completion; P4 relies on the locked read |
| **BUG-072** | **Low** (export formatting) | Confirmed (code: BigDecimal values passed unformatted to `CSV.generate`) | Exported unit costs and quantities may appear as `0.704e-1`; spreadsheets or downstream tools may misread them; stored data unaffected | Display/export only, like the register's Low UI entries; grows more visible once 8-dp costs exist (P1) | P1 | none |
| **BUG-073** | **Medium** (stock integrity under concurrency; reservation bypass) | Suspected (code: availability read before the transaction, no product lock) | Concurrent laundry consumption and postings can take the same stock, driving on-hand below zero or below approved reservations | Same workflow as BUG-065 (Medium); concurrency class of BUG-053; laundry is the only ledger writer outside the posting services; blocks safe packaging integration | P2 (foundation), P4 (packaging) | P4 packaging integration |
| **BUG-074** | **Medium** (traceability of stock movements) | Confirmed (code: no `log_audit` in `StockTransferPoster`; issue and transfer voids called without `audit: true`) | Transfer postings and issue / transfer voids — which move valued stock — leave no audit entry; the movements themselves are still recorded with document and user | Same level as BUG-061 (Medium, traceability); above BUG-044 (Low–Medium, configuration only) because these are stock and value movements covered by CLAUDE.md's "every financial action must generate an audit event" | P2, before P4 (Decision 13) | P4 |

These are proposals. The user approves or changes each severity before registration (§15.4).

### 15.4 Formal registration (future task, Decisions 12, 20)

After the user approves the §15.3 severities, a separate, approved documentation change adds BUG-070 – BUG-074 to `docs/quality/deferred-bugs.md`, following its conventions (summary table row + `## BUG-NNN` section: source, discovered date, area, severity, evidence level, status, evidence, impact, reason for phase, acceptance). Numbers BUG-070 – 074 were verified free on 2026-11-22 (the register still ends at BUG-069 in revision 4) and must be re-checked at registration. **This document does not register them; none is fixed.**

---

## 16. BUG-070 investigation (Decisions 9, 17, 19, 21)

The figures below are the verified revision 3 findings; revisions 4 and 5 ran no query and found no contradicting evidence. Decision 21 (revision 5) is applied in §16.9.

### 16.1 Question

Earlier finding: a full recalculation replays in document-date order, normal posting uses posting order, and a posting-order replay still did not reproduce the stored average of one Development product. Why?

### 16.2 Evidence inspected (read-only, Development, `SET TRANSACTION READ ONLY`, rolled back)

* Code: `ProductCostUpdater#apply_receipt`, `GoodsReceiptPoster#post_item`, `ProductCostRecalculator#recompute!` / `#live_movements`, `AdjustmentPoster#call` (recompute after every posting), `DocumentVoider#call` (recompute after every void), ActiveModel decimal casting.
* Data: all movements (id, `occurred_on`, `created_at`, direction, reason, quantity, unit cost, source, source status) for the product; `products.average_cost_price`, `initial_cost_price`, `last_purchase_price`, `updated_at`; `AuditLog` rows for the product; and a full-history path simulation for every product.

### 16.3 The product

Product id **346** (internal id only). 34 movements, none from a voided document. Stored average **824.5153**; initial cost 770.0000; last purchase 820.0000; `updated_at` 2026-10-26 17:18:29 UTC.

| Replay | Result |
|---|---|
| Posting order (id), per-step 4 dp | 825.3515 |
| Posting order including voided documents | 825.3515 |
| Document-date order (current recalculator), per-step 4 dp | 824.5153 |
| Document-date order, full precision, cast once (exact recalculator) | **824.5153 = stored** |

Relevant history:

* Receipt GR#108 (movement 1672): dated and posted 2026-10-10, 5 @ 820.00. On-hand before it (posting order) = 4 → incremental average (4 × 832.0409 + 5 × 820) ÷ 9 = **825.3515**; issues posted afterwards (movements 1727 … 1968) carry 825.3515.
* Issue SI#115 (movement 1727): **dated 2026-10-05, posted 2026-10-19** — back-dated before the receipt.
* Adjustment SA#11 (movement 1976, `manual_correction`, +1): posted 2026-10-26 17:18:29 — exactly `products.updated_at`. `AdjustmentPoster` then ran `ProductCostRecalculator`, which replays by document date: SI#115 now precedes GR#108, so on-hand before the receipt is 3 → (3 × 832.0409 + 5 × 820) ÷ 8 = **824.5153**; the two later issues (2059, 2071) carry 824.5153.
* No `AuditLog` row exists for the product: the change from 825.3515 to 824.5153 is recorded nowhere except as the side effect of the adjustment.

### 16.4 Generalisation

A read-only path simulation of every product — the incremental update at each receipt in posting order (on-hand = full ledger before it, cast to 4 dp) and an exact recalculator replay at the end of each adjustment posting and each void (movements existing at that moment, documents voided by then excluded, date order, full precision, cast once) — **reproduces the stored average of all 154 products with movements (154 / 154)**. The last writer was the incremental update for 108 products and a recalculation for 46.

### 16.5 Explanation

* The discrepancy is **not** caused by rounding/precision, historical edits, voids, or missing or inconsistent records on this product: it has no voided documents, every value is reproduced exactly, and both orderings use the same arithmetic.
* It **is** caused by **two calculation paths with different ordering semantics**, both writing the same stored average: the incremental update (posting order, weight = on-hand at posting) and the recalculation (document date, voided documents excluded). With back-dated documents the two disagree; the stored value is whichever path wrote last.
* Hence: a posting-order replay reproduces products whose average was last written incrementally (and those unaffected by back-dating), but **not** product 346, whose stored average is itself a date-order replay result. A date-order replay reproduces 346 but not the 18 products whose last writer was incremental after back-dated documents (104.57 SAR total valuation difference; largest +37.50). **Neither single ordering reproduces all stored values.**

### 16.6 Consequences for a fix (not chosen — Decision 9)

| Option | Effect on Development stored averages at the next recalculation | Accounting meaning |
|---|---|---|
| A. Posting order everywhere | 1 product changes (346: 824.5153 → 825.3515; × 3 on hand = +2.5086 SAR) | cost follows the sequence in which stock was actually recorded; back-dating never re-costs |
| B. Document date everywhere (incremental receipts would need a replay whenever a back-dated document is posted) | 18 products change (104.57 SAR) | cost follows document dates; back-dated documents re-cost later history; issue snapshots already posted keep their old cost |
| C. Keep both (status quo) | every future adjustment / void can move averages | path-dependent |
| D. Document date for receipts, posting order for issues, or other hybrids | to be analysed | needs a stated policy |

Each option also needs the precision rule (8-dp per-step `blend`) and a stated handling of voided documents (replay excludes them; the incremental path saw them while live). Whatever option is chosen, the approved safeguards apply: every changed average is audited (§11.1, Decision 17) and a replay that goes below zero stops for that product with a diagnostic (§11.2, Decision 19; 7 Development products). The table is kept as the revision 3 / 4 record; revision 5 re-frames the choice under Decision 21 in §16.9.5, where open-period alternatives W1 – W4 replace options A – D.

### 16.7 Prerequisites before a fix is selected

| # | Prerequisite | State in revision 5 |
|---|---|---|
| 1a | **Closed-period policy for back-dated purchase invoices** | **approved** (Decision 21, §16.9) |
| 1b | **Ordering inside open periods** (§16.9.5) | **recommendation W2, awaiting user approval** (Q1) |
| 1c | **Effective costing date rule** inside the first open period (§16.9.2) | **recommendation E3, awaiting user approval** (Q4) |
| 1d | **Accounting-period model**: granularity, who closes, reopening, closing snapshot (§16.9.4) | **open** (Q5, Q6) — no such concept exists today [Fact §2.6] |
| 1e | Treatment of history at rollout: which past periods are closed and which values become their closing snapshot (§16.9.3) | **open** (Q7) |
| 1f | Closed-period rule for other operations (§16.9.6) | **open** (Q8 – Q13); Decision 21 is not extended to them |
| 2 | **Production read-only evidence** (§17): stored-average writers, back-dated documents per period gap, valuation impact of W1 / W2, negative-replay products | **open** (gate G16, not run) |
| 3 | Reports and workflows depending on either ordering or on movement dates (stock-value reports read the current average [Fact §2.6]; `Inventory::ConsumptionLedger` uses posted snapshots) — every report, export and finance figure | **open** |
| 4 | Negative-balance behaviour under replay | **safeguard approved** (Decision 19, §11.2); scope question Q2 remains |
| 5 | Audit behaviour for every changed average cost | **safeguard approved** (Decision 17, §11.1) |

**BUG-070 remains unresolved** until 1b – 1f, 2 and 3 are answered and a fix is approved.

### 16.8 Status summary

| Category | Content |
|---|---|
| **Verified current behaviour [Fact]** | Two writers with different ordering semantics; the stored average is whichever ran last (product 346: 824.5153 by date-order recalculation after SA#11; posting-order value 825.3515); reproduced for 154 / 154 products (108 incremental, 46 recalculation); no audit of any average change; the recalculator silently continues through negative balances; no accounting period exists, so nothing is closed today (§2.6) |
| **Approved business policy [Decision 21]** | A back-dated purchase invoice keeps its original date; if that period is closed, its costing impact goes to the first open period; closed periods' costs, issues and reports are never retroactively recalculated |
| **Approved safeguards [Decisions 17, 19]** | Audit every changed average in the same transaction (§11.1); stop and diagnose per product on a negative replay balance, never repair (§11.2) |
| **Recommendations awaiting approval [Proposal]** | Open-period ordering W2 (§16.9.5); effective costing date E3 (§16.9.2); closing snapshots and replay from the latest snapshot (§16.9.3 – 16.9.4) |
| **Unresolved [Unresolved]** | Period model (Q5, Q6); history at rollout (Q7); other operations (Q8 – Q13); Production evidence and report dependencies (§16.7 #2, #3) |
| **Decision still required from the user** | Q1, Q4 – Q13 (§19.1); A2 (P4 dependency) |

The stored average is **not** treated as correct accounting policy merely because the historical reconstruction reproduces it: the reconstruction explains how each value was produced, not which value the business intends. Neither posting-order nor document-date replay is selected for that reason (Decision 9); the §16.9.5 recommendation rests on the policy arguments stated there.

### 16.9 Closed-period costing policy (Decision 21)

#### 16.9.1 What the decision covers

* WorkPulse has no supplier-invoice document; the cost-bearing purchase document is the **goods receipt**, whose only business date is `received_on` [Fact §2.6]. This design therefore applies Decision 21 to **posted goods receipts** (the movement reason `goods_receipt`), treating `received_on` as the invoice date. [Unresolved Q5a: confirm that `received_on` is the date the policy means, or whether a separate supplier-invoice date must be captured.]
* Not covered unless separately approved (§16.9.6): opening balances (the other cost-bearing inflow), issues, adjustments and stock-count adjustments, transfers, voids and count reopens, laundry consumption, unit conversions.

#### 16.9.2 Three dates [Proposal for storage; the distinction itself follows Decision 21]

| Date | Meaning | Where it lives | Changes? |
|---|---|---|---|
| **Original document date** | the business date on the document (the invoice date, e.g. 5 October) | `goods_receipts.received_on` → movement `occurred_on` | never; always shown on the document, the movement and its audit |
| **Posting / recording timestamp** | when the document was recorded in WorkPulse (e.g. 10 November 14:02) | movement `created_at`, receipt `confirmed_at`, the `post` audit entry | never; decides which periods were closed at that moment |
| **Effective costing date** | the date whose period carries the document's costing impact | new movement column `costing_on` (date, set at posting, **immutable**) | never recomputed — later closes or reopens do not move it |

Rule: `costing_on = occurred_on` when the period containing `occurred_on` is open at posting time; otherwise a date inside the **first open period**. Which date inside it:

| Alternative | `costing_on` (Oct 5 invoice, entered Nov 10, October closed) | Consequence |
|---|---|---|
| E1 first day of the first open period | 1 Nov | the invoice blends before every November movement, re-weighting November's already-posted outflows in the replay |
| E2 last day of the first open period | 30 Nov | blends after all of November, including activity not yet recorded; the average reflecting the invoice is "in the future" until month end |
| **E3 (recommended)** the posting business day if it lies in the first open period, otherwise the last day of the first open period | 10 Nov; (entered 3 Dec with October closed and November still open → 30 Nov) | matches the moment the invoice was actually recorded whenever possible, so it blends with the stock that existed then; always inside the first open period, as Decision 21 requires |

Business days use `BusinessDay.current(context: business)` (CLAUDE.md), never `Date.current`.

#### 16.9.3 Effect on cost replay and the historical average

* **Closed periods are frozen.** No replay may change a value belonging to a closed period. A from-scratch replay cannot guarantee this: it re-derives closed-period averages every time, and the current recalculator also removes voided documents from the entire history [Fact §2.6], which re-costs closed periods. Proposal: at each period close, write an append-only **closing snapshot** per product (on-hand, average, last purchase price, the highest movement included); every replay starts from the product's latest snapshot and replays only movements whose `costing_on` lies in open periods. Snapshots are never updated; reopening (if ever allowed, Q6) appends a superseding snapshot, audited.
* **Replay key:** `costing_on` replaces `occurred_on` for costing; within an open period, the order is the §16.9.5 choice.
* **Issued costs:** issue, transfer and adjustment snapshots (`unit_cost`) are never rewritten under any alternative (Earlier 1, 8), so closed-period issues keep their cost by construction; the closed period's reports are protected only once valuation reports read period snapshots instead of the current average (§16.7 #3).
* **Existing data:** no period has ever been closed, so Decision 21 alone changes **no** stored average today. Every historical movement is in an "open" period until periods are introduced. The values used as the first closing snapshots therefore decide what history becomes frozen (Q7): freezing today's stored averages would freeze path-dependent values (§16.5); replaying first would move the 1 (W2) or 18 (W1) Development products before freezing.
* **Safeguards unchanged:** §11.2 applies to the replay from the snapshot (the diagnostic adds the starting snapshot and the periods involved); §11.1 audits every changed average, with two new triggers: `backdated_receipt_posted` (replay caused by a receipt whose `costing_on` precedes later open-period movements, W1 only) and `rollout_replay` (Q7); `metadata.costing_on` and `metadata.periods` are added.

#### 16.9.4 Accounting periods — prerequisite capability [Proposal; the business rules are Q5 – Q6]

Nothing exists today [Fact §2.6]. Minimum needed: an `inventory_accounting_periods` record per business (start, end, status `open` / `closed`, closed by / at, reason); a close action through a service with its own narrow permission (owners implicit; no default role; CLAUDE.md permission steps), fail-closed audit, locked against concurrent postings (a posting reads period status under the same lock the close takes); closing snapshots written in the close transaction; closed periods refuse nothing at entry — documents are still accepted with their original date, only their `costing_on` moves (Decision 21).

#### 16.9.5 Replay inside open periods — alternatives, consequences, recommendation

After `costing_on` has placed every document in an open period, the order inside the open periods still has to be chosen. In every alternative: closed periods are never touched; issued cost snapshots are never rewritten; §11.1 and §11.2 apply.

| Alternative | Order inside open periods | Consequences |
|---|---|---|
| **W1 — effective date** | `costing_on`, then posting time | Original dates count while their period is open: a receipt dated 5 Oct entered 20 Oct (October still open) re-costs October's later history. The replayed average then differs from the costs already charged to issues posted in between (snapshots are immutable), leaving an unexplained residue in stock value until the period closes; no revaluation entry exists to carry it. Receipt posting must trigger a replay whenever `costing_on` precedes later movements (the incremental update is no longer enough). Development, all history open: ≈ revision 3 option B, 18 products / 104.57 SAR change. |
| **W2 — posting time within the costing period** | the period of `costing_on`, then `created_at` (posting time) | Every document is costed when it was recorded (or, for a closed-period document posted into a later period, inside the first open period per E3). The replay reproduces each issue's cost snapshot (up to rounding), so stock value, issued cost and the average stay mutually consistent; the incremental update and the replay become one semantics, and routine postings need no replay. Original dates inside an open period have no costing effect. Development, all history open: ≈ option A, 1 product (346) +2.51 SAR. |
| W3 — hybrid (receipts by date, outflows by posting time) | mixed | weights inflows and outflows on different clocks; hard to explain or audit; no stated policy supports it |
| W4 — status quo | two writers | path-dependent averages (BUG-070 itself); incompatible with frozen closed periods |

**Recommendation: W2** [Proposal — awaiting user approval, Q1]. Reasons (policy, not reproduction): (1) Decision 21 already establishes that a late document is recognised when it can be, not retroactively; W2 applies the same principle inside open periods instead of allowing retroactive re-costing there; (2) issued costs are immutable snapshots (Earlier 1, 8), and only W2 keeps the average consistent with them — W1 creates residues with no ledger entry to explain them, against the audit-first rule; (3) one costing semantics for posting and replay removes the BUG-070 mechanism instead of choosing which writer wins. Cost of W2 the user must accept: inside an open period the original document date is informational for costing. If the business wants open-period re-costing by document date, W1 is the alternative, with a revaluation / residue policy added. The fact that W2 is close to the stored values for 108 products is **not** a reason for the recommendation (Decision 9).

#### 16.9.6 Other cost-affecting operations — separate policy questions (Decision 21 not extended)

| # | Operation | Why it matters for closed periods | Question |
|---|---|---|---|
| Q8 | Opening balances (product import, cost-bearing IN) | the other inflow that moves the average; usually dated to the go-live date | Same rule as purchase invoices? |
| Q9 | Back-dated issues, laundry consumption, adjustment decreases | change the on-hand weight of later receipts in a replay; their own cost is snapshot at posting | Should their `costing_on` also move to the first open period when their date is closed? |
| Q10 | Voids and stock-count reopens of documents whose date is in a closed period | today the reversal is dated `BusinessDay.current` but the recalculator removes the voided document from all history, re-costing the closed period [Fact §2.6] | Should a void be costed as a new event in the open period (reversal at original cost), never by removing history? |
| Q11 | Adjustment increases and stock-count adjustments | not cost-bearing today (no average change), but they change replay weights | Same closed-period rule for their dates? |
| Q12 | Transfers | no product-level cost effect (out and in at the same cost); only warehouse-level date reports | Date reports for closed periods: original date or `costing_on`? |
| Q13 | Quantity and movement reports for a closed period | a late receipt dated 5 Oct changes October's quantity reports if they read `occurred_on` | Should period reports read `costing_on` (closed periods unchanged) and documents show the original date? |
| — | Unit conversion (P6) | posts out / in at a factor-adjusted cost | covered when P6 is approved; follows whatever Q9 – Q11 decide |

---

## 17. Production read-only profile — mandatory rollout gate (Decision 16)

Run by an operator with read-only credentials (`SET TRANSACTION READ ONLY`), with results reviewed **before** the rollout plan is approved. Not run during this task; nothing here is Production evidence.

| Area | Checks |
|---|---|
| Products and units | count; `unit_of_measure` / `measure_amount` distribution (after the Measure work is deployed); products with movements per unit; fractional quantities on `pieces` |
| Movement volume and history | rows and size of `inventory_movements` and all item tables; movements per product (max, p95); reasons; back-dated movements (`occurred_on < created_at::date`); maximum cost scale and maximum values (headroom for `numeric(16,8)`) |
| Distribution | warehouses per business; products per warehouse; busiest product/warehouse pairs |
| Reservations and open documents | approved / pending issues; on-hand-below-reserved pairs; open receipts, transfers, counts, laundry batches |
| Back-dated documents and periods (Decision 21) | per business: documents whose `occurred_on` month precedes their posting month, by document type and by gap (months); how many would have fallen into a closed period under monthly closes; products affected; valuation impact of W1 vs W2 from an all-open start and from a hypothetical closing snapshot |
| Average-cost consistency | the §16.4 path simulation; per product: stored vs incremental-path vs posting-order vs date-order replay; valuation impact per BUG-070 option; replays passing below zero, with the §11.2 diagnostic fields computed read-only (first offending movement, balances, likely cause) |
| Audit | existing `AuditLog` volume for inventory documents; expected `average_cost_recalculated` entries per day (adjustments + voids × products); that every business has an owner usable as the system actor (§11.1) |
| Historical compatibility | stock counts by status; legacy count rows; `barcode_type = carton` usage; thresholds in use |
| Query and index impact | `EXPLAIN` of balance queries and reports with the proposed indexes; expected `inventory_packaging_entries` growth (≈ 1–3 entries per packaged movement) |
| Triggers and append-only entries | lock duration estimates for the P1 table rewrites (8 tables) and new constraint triggers; PostgreSQL version; active sessions / maintenance window |
| Observability and rollback | log/metric points for refusals (strict package, reservation, trigger violations); rollback steps per phase; confirmation that rollbacks never rewrite historical rows |

No Production migration, write, backfill or repair is part of this gate.

---

## 18. Implementation plan

General: each phase separately approved; migrations on the disposable test database first; Development only with explicit approval; Production only after §17 and a separate approval. New branch from `origin/main` after the current stack is committed and separated; P3 onwards after the Measure work is merged into `main`. Tests per phase: focused + `spec/services/inventory`, `spec/requests/inventory`, `spec/system/inventory`, `spec/models`, `spec/characterization`, `spec/architecture`, `spec/performance`, `spec/i18n`, `spec/policies`, laundry and finance-report specs where touched; full suite at the end of P4 and P6 (with approval); RuboCop and Brakeman each phase.

### 18.1 Dependencies

Revision 5 splits P1 into P1.A and P1.B because Decision 21 requires an accounting-period capability that does not exist [Fact §2.6]; the other dependencies are unchanged unless A2 is approved.

| Phase | Depends on | Notes |
|---|---|---|
| P1.A | overall approval | parallel with P2: precision, BUG-071, BUG-072, §11.1 audit, §11.2 negative-replay stop |
| P1.B | P1.A; approval of Q1, Q4 – Q7, Q10; G16 | accounting periods, closing snapshots, `costing_on`, BUG-070 fix (§16.9) |
| P2 | overall approval | parallel with P1; BUG-074 and BUG-073 foundation |
| P3 | Measure work merged into `main` | can start alongside P1/P2 |
| P4 | P1, P2, P3 (approved; **proposal A2:** P1.A instead of all of P1) | relies on P1.A's locked cost reads (BUG-071), precision and audit, P2's audit (BUG-074) and locking (BUG-073). Technical basis for A2: opening packages has no cost effect (§11) and the planner carries no money (§6), so packaging does not depend on the replay order; without A2, packaging waits for the period capability |
| P5 | P4 | |
| P6 | P1, P2, P3, P4 | |

```
P1.A (cost precision, BUG-071, BUG-072, avg-cost audit, negative-replay stop) ──► P1.B (periods, BUG-070) ┐
P2 (reservations, BUG-073 foundation, BUG-074) ───────────────────────────────────────────────────────┼──► P4 ──► P5
Measure work in main ──► P3 (packaging structure) ────────────────────────────────────────────────────┘     └───► P6
```

### 18.2 Phases

**P1.A — Cost Precision, average-cost audit, negative-replay isolation, BUG-071, BUG-072.**

| Aspect | Content |
|---|---|
| Scope | Widen 10 columns to `numeric(16,8)` — `inventory_movements.unit_cost`, `products.average_cost_price` / `initial_cost_price` / `last_purchase_price`, `goods_receipt_items` / `stock_issue_items` / `stock_transfer_items` / `stock_adjustment_items` `.unit_cost`, `laundry_batch_consumptions.unit_cost_snapshot`, `purchase_request_items.unit_price` (money totals and `cost_per_towel` unchanged); `Inventory::CostPrecision` (`unit`, `money`, `blend`); explicit 8-dp rounding in item models; BUG-071 locks; BUG-072 fixed-point exports; unit-cost display helper (Decisions 11, 18) on screens, reports, exports and audit displays; §11.1 audit of every changed recalculated average (Decision 17); §11.2 per-product negative-replay stop and diagnostic (Decision 19); the existing recalculator's ordering is **not** changed in P1.A (BUG-070 is P1.B) |
| Dependencies | overall approval |
| Files / services | one migration; `app/services/inventory/{product_cost_updater,product_cost_recalculator,goods_receipt_poster,stock_issue_poster,stock_transfer_poster,adjustment_poster,document_voider}.rb`; new `app/services/inventory/cost_precision.rb` and a recalculation diagnostic value object; `app/models/{goods_receipt_item,stock_issue_item,stock_transfer_item,stock_adjustment_item,purchase_request_item,laundry_batch_consumption}.rb`; `app/services/inventory/reports/movements_export.rb`; `app/services/finance/reports/expense_details_csv_exporter.rb`; `app/services/inventory/imports/product_importer.rb`; `app/helpers/application_helper.rb`; cost views and `purchase_request_form_controller.js`; `OrganizationAccess::PermissionRole` and a policy only if a manual / batch recalculation entry point is approved; EN + AR locales |
| Schema | 10 column widenings (table rewrites); no new tables (audit uses `audit_logs`) |
| Tests | costing per poster and voider; §11 verified figures; concurrent receipts (two connections); migration up/down with row-by-row equality and a down that refuses once values exceed 4 dp; export and display formatting (§12, incl. `25`, `25.5`); all §11.1 and §11.2 tests; BUG-070 tests for the approved semantics |
| Acceptance | §19.2 G3, G13, G17, G18; §19.3 items 23, 24, 26 – 29 |
| Risks | table-rewrite lock time; fail-closed audit makes an audit-write failure block an adjustment or void; §11.2 freezes the averages of negative-replay products (7 on Development) |
| Rollout gates | G16 reviewed; short window with `lock_timeout`; restart to refresh schema caches |

**P1.B — Accounting periods and the BUG-070 fix (Decision 21).**

| Aspect | Content |
|---|---|
| Scope | §16.9: `inventory_accounting_periods`; period close service with its own narrow permission and fail-closed audit; append-only closing snapshots; immutable `inventory_movements.costing_on` set at posting (E3 if approved); one costing semantics for posting and replay (W2 if approved) replacing the two writers; replay from the latest snapshot; handling of voids per Q10; the rollout treatment of history per Q7; valuation reports for closed periods read snapshots (§16.7 #3); EN + AR |
| Dependencies | P1.A; user approval of Q1, Q4 – Q7 and Q10; G16 (Production evidence); report-dependency review (§16.7 #3). Q8, Q9, Q11 – Q13 either approved or explicitly left out (then those operations keep their current dates and behaviour) |
| Files / services | new model(s) and a close service + policy + controller; `OrganizationAccess::PermissionRole`; `app/services/inventory/{product_cost_updater,product_cost_recalculator,goods_receipt_poster,document_voider,adjustment_poster}.rb`; stock-value reports (`CurrentStock`, `WarehouseSummary`, `NoMovement`, `LowStock`, `BranchComparison`); locales |
| Schema | periods table; closing-snapshot table (append-only trigger, dumped by `schema_dumper_database_guards.rb`); `costing_on` column (NULL on history = `occurred_on`; no backfill) |
| Tests | Decision 21 example (5 Oct invoice, entered 10 Nov, October closed → original date kept, `costing_on` 10 Nov, October snapshot and reports unchanged, November average changes, audited); E3 fallback (November still open → last day of November); posting during a concurrent close (two connections); replay never reads movements before the snapshot; voids per Q10; §11.1 / §11.2 under the new replay; W2 equivalence (replay reproduces every issue snapshot up to rounding); idempotent replays; permission refusal for close |
| Acceptance | G2, G20 – G22; §19.3 items 25, 30 – 34 |
| Risks | the first closing snapshots freeze whatever values are chosen (Q7); every average change is audited, but the change itself may surprise users |
| Rollout gates | G16 incl. the Decision 21 checks; Q7 decided; rollout replay (if any) run as an audited batch with §11.2 diagnostics reviewed before snapshots are written |

**P2 — Reservation Protection, BUG-073 foundation, BUG-074.**

| Aspect | Content |
|---|---|
| Scope | §10.2 – 10.3 reservation invariant in every removal workflow; `StockAvailability.removal_shortfalls`; laundry lock and in-transaction check (BUG-073); transfer posting audit and issue / transfer void audit in the service layer (BUG-074) |
| Dependencies | overall approval |
| Files / services | `app/services/inventory/{stock_availability,stock_transfer_poster,adjustment_poster,stock_count_approver,stock_count_reopener,document_voider}.rb`; `app/services/laundry/{batch_material_consumer,laundry_batch_service}.rb`; `app/controllers/inventory/{stock_issues,stock_transfers}_controller.rb`; EN + AR locales |
| Schema | none |
| Tests | refusal per workflow naming the reserving issues; §10.6 concurrency; posting, voiding, rollback (no movement, no entry), duplicate requests (double-click void → one reversal, one entry), audit idempotency, audit-write failure per BUG-003 (`log_audit` savepoint behaviour documented per caller) |
| Acceptance | G4, G5; §19.3 items 8, 19 |
| Risks | existing on-hand-below-reserved states block later removals (0 on Development; Production per §17) |
| Rollout gates | G16 reservation checks reviewed; no data change |

**P3 — Packaging Structure.**

| Aspect | Content |
|---|---|
| Scope | `product_packaging_levels`; §4.5 trigger functions; `Structure`, `Configurator`; four-level limit; add / retire / replace rules; `measure_amount` sync; base-unit lock (§4.6); Packaging section UI; EN + AR |
| Dependencies | Measure work merged into `main` |
| Files / services | new `app/models/product_packaging_level.rb`, `app/services/inventory/packaging/{structure,configurator}.rb`; `app/models/product.rb`; `app/controllers/inventory/products_controller.rb`; `app/views/inventory/products/{_form,show}.html.erb`; `app/helpers/inventory_helper.rb`; `product_importer.rb`; locales; updated Measure specs |
| Schema | new table, indexes, check constraints, deferred constraint triggers, delete-refusal trigger (dumped by `schema_dumper_database_guards.rb`) |
| Tests | chain validation; fifth level refused (database and model); trigger: insert / update / retire / replace / direct `measure_amount` write / delete refused / products without levels unaffected / error mapped in Configurator; base-unit lock; no stock behaviour change |
| Acceptance | G6, G7, G8; §19.3 items 11 – 13 |
| Risks | trigger behaviour under deferred checks; Measure spec rewrite |
| Rollout gates | drop table and triggers while unused (rollback); no backfill |

**P4 — Packaging Ledger and Posting.**

| Aspect | Content |
|---|---|
| Scope | entries table, line breakdowns, `Balances`, `Planner`, `EntryWriter`, `QuantityEntry`; every poster; `DocumentVoider` (Decision 5 restore + preview); `GoodsReceiptVoider`; the four `#reversal_entries`; `StockLevels`, `StockAvailability`; `StockIssueApproval` (Decision 6); `StockIssueDraftService`, `StockIssueEditor`; `PurchaseRequestCreator` / `Updater` / `BulkApproval` (Decisions 7, 15); `GoodsReceiptDraftService`, `GoodsReceiptsController`; laundry via the planner; reservation enforcement; packaging data in posting and void audit entries |
| Dependencies | P1, P2, P3 |
| Files / services | the services above; line partials and show pages; `line_items`, `barcode_scanner_controller.js`, `lib/product_option.js`, `purchase_request_form_controller.js`; preview endpoint; product search / barcode lookup payloads |
| Schema | `inventory_packaging_entries` (composite FK, append-only trigger); nullable `inventory_movements.unit_of_measure`; line breakdown columns |
| Tests | planner properties; Appendix A examples; each poster in base and package modes; voids after later movements; multiple warehouses; §10.6 concurrency; regression harness (products without packaging produce identical rows) |
| Acceptance | G9 (structure side), G10, G11, G12, G14; §19.3 items 1 – 5, 9, 10, 14 – 17 |
| Risks | widest change set — one planner and one writer |
| Rollout gates | G16 query / index impact reviewed; full suite with approval |

**P5 — Stocktaking, Imports, Reports and display formatting.**

| Aspect | Content |
|---|---|
| Scope | §8 (incl. the zero-difference exception and its regression tests); count importer / CSV; product and issue imports; reports and thresholds display; unit-cost and purchase-remaining formatting completed on every packaging-aware screen, report and export (§12); optional barcode-to-level link |
| Dependencies | P4 |
| Files / services | `app/services/inventory/{stock_count_recorder,stock_count_completion,stock_count_approver,stock_count_reopener,stock_count_creator,stock_count_csv}.rb`; `app/models/{stock_count_item,stock_adjustment_item}.rb`; `app/services/inventory/imports/{stock_count_importer,stock_issue_importer,stock_issue_import_row_resolver,product_importer}.rb`; `Reports::CurrentStock`, `WarehouseSummary`, `LowStock`, `LowStockQuery`, `NoMovement`, `BranchComparison`, `Movements`, `MovementsExport`, `ConsumptionLedger`, `AvailabilityFigures`, `ProductAvailabilityOverview`, availability views |
| Schema | stock count per-level breakdown columns |
| Tests | §8.5 regression tests; Appendix A count rows; reopen; import paths; report figures; formatting |
| Acceptance | G9; §19.3 items 6, 7, 10 |
| Risks | the zero-difference exception widening beyond stocktake (prevented by §8.3) |
| Rollout gates | open counts re-baselined when structure changes |

**P6 — Unit Conversion Document.**

| Aspect | Content |
|---|---|
| Scope | §14: permission `convert_inventory_units`, preview, reason, fail-closed audit, atomic posting, reversal, cost behaviour (average ÷ factor; replay cost-bearing) |
| Dependencies | P1, P2, P3, P4 |
| Files / services | model, line model, `UnitConversionPoster`, `UnitConversionPreview`, policy, controller, views; `OrganizationAccess::PermissionRole`; `ProductCostRecalculator`; `InventoryMovement::REASONS`; locales |
| Schema | `inventory_unit_conversions` and lines; new movement reasons |
| Tests | preconditions, permission refusal, owner access, atomic rollback, fail-closed audit, per-warehouse packaging selection, trigger-consistent `measure_amount`, void with / without later movements, cost exactness, §11.1 entry when the conversion changes the average |
| Acceptance | §19.3 item 18 |
| Risks | divisibility failures on legacy stock |
| Rollout gates | full suite with approval; G16 open-document counts |

---

## 19. Gates, acceptance and open questions

### 19.1 Remaining open questions

Removed because the 21 decisions answer them: revision 3's Q2 (replay audit → Decision 17), Q3 (unit-cost display → Decision 18), Q5 (negative replays → Decision 19). Revision 3's Q4 (severities) is now the proposal in §15.3, awaiting approval (A1). Revision 4's Q1 is narrowed: the closed-period part is settled by Decision 21.

| # | Question | Why still open | Blocks | Evidence needed | User approval |
|---|---|---|---|---|---|
| Q1 | **Replay order inside open periods:** approve W2 (posting time within the costing period, recommended) or choose W1 (effective date, with a residue / revaluation policy) — §16.9.5 | Decision 21 covers closed periods only; the order inside open periods is a separate accounting choice | P1.B (BUG-070 fix) | Production profile (§17, W1 vs W2 impact); report-dependency review (§16.7 #3) | **Yes** |
| Q2 | **Scope of Decision 19:** does the stop-and-diagnose rule also govern the automatic recalculation after every adjustment / void (the design assumes yes: the posting proceeds, the average stays unchanged, a diagnostic entry is written), or only explicit BUG-070 replays? | The decision is titled "during BUG-070 replay", but the automatic recalculation is the same replay | §11.2 in P1.A | the user's confirmation; Production count of negative-replay products (§17) | **Yes** |
| Q3 | **Incremental receipt updates:** audit the average change made by `ProductCostUpdater` like §11.1 (recommended), or leave it to the receipt's posting entry? | Decision 17 names recalculations; under W2 the incremental update stays the routine writer | §11.1 scope in P1.A | none; user choice | **Yes** |
| Q4 | **Effective costing date inside the first open period:** approve E3 (posting business day, else last day of the first open period) or choose E1 / E2 — §16.9.2 | Decision 21 names the period, not the day | P1.B | none; user choice | **Yes** |
| Q5 | **Accounting-period model:** granularity (monthly as in the example?), per business, calendar vs business-day boundaries; Q5a: is `goods_receipts.received_on` the invoice date the policy means, or must a separate supplier-invoice date be captured? | No period concept exists [Fact §2.6]; the policy presupposes one | P1.B | the business's closing practice | **Yes** |
| Q6 | **Closing and reopening:** who closes a period (new narrow permission), whether a closed period may ever be reopened, and by whom | Determines snapshot immutability and audit | P1.B | none; user choice | **Yes** |
| Q7 | **History at rollout:** which past periods are declared closed, and whether their first closing snapshots take today's stored (path-dependent) averages or a replayed value | Nothing is closed today, so Decision 21 changes no stored value until this is decided; the 154 / 154 reproduction shows today's values are path-dependent, not policy-correct | P1.B rollout | Production profile (§17) | **Yes** |
| Q8 – Q13 | **Other operations** (opening balances, back-dated outflows, voids / reopens, adjustment increases, transfers, closed-period quantity reports) — §16.9.6 | Decision 21 is limited to purchase invoices and is not extended without approval | Q10 blocks P1.B (the replay must handle voids); the others block only their operation, which otherwise keeps today's dates and behaviour | none; user choice per operation | **Yes** |

| # | Approval item (not a blocker for this document) | Blocks |
|---|---|---|
| A1 | Approve or change the proposed severities of BUG-070 – BUG-074 (§15.3) | the formal registration task (§15.4) only |
| A2 | Narrow P4's dependency from all of P1 to P1.A (§18.1) | P4 start timing only |

### 19.2 Mandatory gates

| Gate | Requirement | Status |
|---|---|---|
| G1 | Architecture review approved | pending |
| G2 | BUG-070 investigation complete and discrepancy explained before its fix is selected | mechanism explained (§16.5); closed-period policy approved (Decision 21); open-period order, period model, history and Production evidence pending (§16.7) |
| G3 | BUG-071 and BUG-072 included in P1 | specified |
| G4 | BUG-073 locking and transaction requirements in P2 | specified |
| G5 | BUG-074 fixed and audited in P2 before P4 | specified |
| G6 | Measure integration and base-unit locking specified | specified (§4.5, §4.6) |
| G7 | Four-level maximum specified and enforced | specified (§4.1) |
| G8 | Measure sync protected by Configurator and database trigger | specified (§4.5) |
| G9 | Stocktake-only repackaging and zero-quantity packaging corrections specified | specified (§8) |
| G10 | Receipt voiding restores free packages and removes opened quantity as base units | specified (§9) |
| G11 | Approval warning non-blocking; posting authoritative | specified (§10.4) |
| G12 | Purchase remaining in purchase unit, ≤ 3 dp | specified (§7.1, §12) |
| G13 | Unit-cost display: ≤ 8 dp, zeros stripped (`25`, `25.5`), never scientific | specified (§12) |
| G14 | Historical records untouched | specified (§13, §11.2) |
| G15 | Regression, concurrency, reversal and full-suite tests specified | specified (§18) |
| G16 | Production read-only profile completed and reviewed before rollout approval | **not run** (§17) |
| G17 | Every changed recalculated average audited in the same transaction, none on failure or no change | specified (§11.1); Q3 open on scope |
| G18 | Negative replay stops per product with a diagnostic; nothing repaired or written | specified (§11.2); Q2 open on scope |
| G19 | Severities approved by the user before BUG-070 – 074 are registered | **pending** (A1) |
| G20 | Closed periods never changed by a back-dated purchase invoice: original date kept, costing in the first open period, no retroactive recalculation (Decision 21) | specified (§16.9); depends on Q4 – Q7 |
| G21 | Accounting-period model, close permission and closing snapshots approved before P1.B | **pending** (Q5, Q6) |
| G22 | Rollout treatment of history approved and its replay diagnostics reviewed before the first snapshots are written | **pending** (Q7) |

### 19.3 Acceptance checklist

1. Every Appendix A example produces the stated totals and packaging state.
2. Opening packages never changes total stock or cost.
3. No package or loose balance becomes negative in any workflow or concurrency test.
4. Strict package requests never substitute loose content or lower levels.
5. Receipt void after opening restores only free packages, removes the rest as base quantity, never reseals; preview matches posting.
6. Repackaging only through Stocktake; manual / import zero-difference lines stay invalid.
7. Packaging-only stocktake lines write `count_correction` entries and no movement; no-difference counts are no-ops; reopen reverses.
8. Reservations protected in every removal workflow of §10.3.
9. Approval warning non-blocking; posting fails clearly and leaves the issue approved and reserved.
10. Purchase remaining shown in the purchase unit (≤ 3 dp, truncated, base equivalent when inexact); over-receipt checked in base units.
11. Base-unit change refused once movements exist, except via conversion.
12. Fifth packaging level refused (database and model).
13. `measure_amount` cannot diverge from the innermost level (validation + trigger), and products without levels are unaffected.
14. Products without packaging produce byte-identical outputs to today.
15. No historical movement, count, cost or balance rewritten.
16. Packaging entries append-only and same-product (trigger, composite FK).
17. Transfers atomic with equal base quantities; loose never arrives sealed.
18. Conversion enforces permission, preconditions, divisibility, explicit packaging selection, atomicity, fail-closed audit.
19. Every posting and void writes an audit entry (BUG-074).
20. BUG-070 – BUG-074 severities approved (A1) and registration completed before P1.A merges.
21. EN and AR complete (`spec/i18n`); RTL verified.
22. Focused, regression, concurrency and full-suite runs green per phase.
23. P1: exactly the 10 listed columns widened; every value equal row by row; down migration guarded.
24. P1: unit-cost display and exports follow §12 (`25`, `25.5`, `0.7`, `0.704`, `0.00000125`; no scientific notation).
25. P1.B: BUG-070 fix (once approved) reproduces the chosen semantics with one costing semantics for posting and replay.
26. P1: every recalculation that changes an average writes one `average_cost_recalculated` entry with all §11.1 fields, in the same transaction; none when unchanged; none after a failure; an audit-write failure rolls back the posting.
27. P1: automated runs carry the system actor and `metadata.system: true`; manual / batch runs need their permission.
28. P1: a negative replay balance stops that product only — no write, no success entry, a complete diagnostic — and other products continue (or the whole run refuses when isolation is impossible).
29. P1: no run inserts opening balances, skips, reorders or modifies any historical row.
30. P1.B: the Decision 21 example — invoice dated 5 Oct, entered 10 Nov, October closed — keeps `received_on` / `occurred_on` 5 Oct, gets `costing_on` in November, changes no October snapshot, issue cost or report, and its November average change is audited.
31. P1.B: `costing_on` is set once at posting and never changes when periods later close or reopen.
32. P1.B: every replay starts from the product's latest closing snapshot and never reads or changes closed-period values; snapshots are append-only.
33. P1.B: a posting racing a period close (two connections) gets a consistent `costing_on`.
34. P1.B: operations not covered by an approved answer to Q8 – Q13 behave exactly as today.

---

## 20. Change log

### Revision 6 (this revision)

* Decision 22 (§1.5): implementation authorised; W2 costing, voids as posting-time reversals, no period engine, receipt-posting audit.
* New §21: implementation record — what was built per phase, schema, deviations from this design, test evidence, and what remains (P1.B period capability, P6 Unit Conversion, imports with packaging columns, Production gate G16).

### Revision 5

* Added **Decision 21** (§1.4): closed periods are never silently changed by a back-dated purchase invoice; costing impact in the first open period; scope limited to purchase invoices.
* New §2.6 facts (code and schema reading): no accounting-period concept; goods receipts have only `received_on`; void reversals and laundry dated today; outflow cost snapshots; stock-value reports read the current average; recalculator removes voided documents from all history.
* New §16.9: coverage (goods receipts), the three dates and effective-costing-date alternatives E1 – E3 (E3 recommended), effect on replay (closing snapshots, replay from the latest snapshot, no stored value changes until periods exist), the period capability, open-period alternatives W1 – W4 (W2 recommended on policy grounds, not reproduction), and separate questions Q8 – Q13 for other operations.
* §16.6 re-framed; §16.7 prerequisites and §16.8 status summary updated; §15.2 BUG-070 row and §11 / §11.1 updated (new triggers only if needed).
* §17: back-dated document / period checks added.
* §18: P1 split into P1.A and P1.B (period capability + BUG-070 fix); proposal A2 to make P4 depend on P1.A only; other dependencies unchanged.
* §19: Q1 narrowed; new Q4 – Q13 and A2; gates G20 – G22; checklist items 30 – 34.
* Unchanged: Decisions 1 – 20, the 154 / 154 reproduction and every revision 3 figure, the §11.1 audit and §11.2 negative-balance safeguards, the proposed severities.

### Revision 4

* Added Decisions 17 – 20 (§1.3); noted that Decision 17 settles Decision 10's conditional audit clause and Decision 18 makes Decision 11's whole-number case explicit.
* New §11.1: audit of every changed recalculated average — fields, `log_audit!` in the same transaction, triggers, system actor (`business.owner` convention), idempotency, authorisation, tests.
* New §11.2: per-product negative-replay stop, diagnostic report and likely-cause classification; whole-run refusal when isolation is impossible; nothing repaired.
* §2.4 facts from reading code: `AuditLog` actor required; fail-open vs fail-closed audit; system-actor convention; recalculator call sites and its silent handling of negative balances.
* §12: unit-cost examples table (`25`, `25.5`); audit displays included; former Q3 removed.
* §15.3: proposed severities with evidence, impact, reasoning and the register's conventions; registration moved to §15.4 and now waits for severity approval.
* §16: revision 3 figures preserved unchanged; prerequisites table (§16.7); status summary distinguishing facts, safeguards, policy, approaches and the decision required (§16.8).
* §17: diagnostic and audit-volume checks added to the Production profile.
* §18: per-phase scope / dependencies / files / schema / tests / acceptance / risks / rollout tables; dependencies unchanged.
* §19: open questions reduced to Q1 (BUG-070 policy), Q2 (scope of Decision 19), Q3 (incremental-update audit); severity approval A1; gates G17 – G19; checklist items 24 – 29.

### Revision 3

* Listed all 16 approved decisions (§1); removed the questions they settle (former Q1 replay order, Q2 P1 scope, Q3 unit-cost display, Q4 registration, Q5 BUG-074 phase, Q6 trigger, Q7 remaining-quantity precision, Q8 Production profile → now a mandatory gate).
* **BUG-070:** withdrew the earlier posting-order recommendation; added the read-only investigation (§16) — product 346's stored average is the output of a date-order recalculation triggered by adjustment SA#11; a full path simulation reproduces all 154 products; mechanism explained, fix and accounting policy undecided.
* Register expanded with current behaviour, overlaps, blocking effects and a formal-registration specification (§15).
* BUG-074 fixed to P2 with transactional / idempotency requirements and tests (§15.2).
* Measure sync: specified the deferred constraint triggers, delete refusal, error mapping and interaction with the four-level limit (§4.5).
* Stocktake: four-case classification, narrowly scoped zero-difference exception, authorisation, audit, reopening and regression tests (§8).
* Purchase remaining: ≤ 3 dp, truncated toward zero, base equivalent; extra fractional-carton / box examples (§7.1).
* Consolidated formatting policy (§12).
* Production read-only profile checklist as gate G16 (§17).
* Mandatory gates table (§19.2); acceptance checklist updated.

### Revision 2

* First written version: eight Phase 3 decisions, first BUG-070 – 074 register, stocktake zero-difference finding, P4 depends on P2.

---

## Appendix A — Worked examples

**A. Razor blades** (1 carton = 12 boxes; 1 box = 10 pcs). Start: 1 carton (120).

| Step | Packaging entries | Movement | Result |
|---|---|---|---|
| Issue 3 boxes | breakdown carton −1, box +12; moved box −3 | OUT 30 | 9 boxes = **90** |
| Issue 15 pcs | breakdown box −2 | OUT 15 | 7 boxes + 5 pcs = **75** |
| Void the 3-box issue | moved box +3 | IN 30 | 10 boxes + 5 pcs = **105** (no carton) |

From 1 carton, issue 15 pcs: breakdown carton −1, box +12, box −2 → 10 boxes + 5 pcs = 105.
Transfers (each from 2 cartons + 1 box + 5 pcs = 255): 2 cartons → moved −2 / +2; 3 boxes → breakdown carton −1, box +12, moved box −3, destination +3 boxes; 15 pcs → loose 5, breakdown box −1, destination **15 loose pcs**.

**B. Shampoo** (bottle = 355 ml).

| Step | Entries | Movement | Result |
|---|---|---|---|
| Start | — | — | 12 sealed + 0 ml = 4,260 |
| Issue 100 ml | breakdown bottle −1 | OUT 100 | 11 + 255 ml = 4,160 |
| Issue 200 ml | — | OUT 200 | 11 + 55 ml = 3,960 |
| Transfer 2 bottles | moved −2 / +2 | 710 out and in | 9 + 55 ml = 3,250 |
| Transfer 100 ml | breakdown bottle −1 | 100 out and in | 8 + 310 ml = 3,150; destination +100 ml loose |
| Count 8 sealed + 300 ml (quantity only) | — | adjustment OUT 10 | 8 + 300 ml = 3,140 |
| Count 7 sealed + 655 ml (packaging only) | count_correction bottle −1 | **none** | 7 + 655 ml = 3,140 |
| Count 7 sealed + 655 ml again | — | — | no difference → no-op |

Strict: 0 sealed + 355 ml loose → "1 full bottle" refused; "355 ml" allowed.
Bag → g (bag = 25,000 g): receive 3 bags at 47.30 → 75,000 g, 0.00189200/g, value 141.9000; issue 1,500 g → breakdown bag −1 → 2 bags + 23,500 g; cost 2.8380.

**C. Mixed units** (carton → box → piece).

| Step | Entries | Movement | Result |
|---|---|---|---|
| Request 2 cartons at 120.00 | — | — | 240 pcs due ("2 cartons") |
| Receive 1 carton + 6 boxes | moved carton +1, box +6 | IN 180 | due 60 ("0.5 carton (6 boxes)"); line total 180.0000; 1.00000000/pc |
| Issue 4 boxes | moved box −4 | OUT 40 | 1 carton + 2 boxes |
| Issue 12 pcs | breakdown box −2 | OUT 12 | 1 carton + 8 pcs |
| Transfer 1 carton | moved −1 / +1 | 120 out and in | source **8 pcs** (180 − 40 − 12 − 120) |
| Count 0 / 0 / 8 | — | — | no-op |

**D. Receipt void after opening** — §9 example (0 cartons + 5 boxes after voiding R1).

---

## 21. Implementation record (revision 6, Decision 22)

### 21.1 Built

| Phase | Implemented | Main files |
|---|---|---|
| P1.A cost precision and safety | 10 cost columns `numeric(12,4)` → `numeric(16,8)` (down migration refuses once values exceed 4 dp); single average writer `Inventory::AverageCost` (W2: blend at posting; a voided cost-bearing inflow is unblended at the void's posting time; unchanged when no stock remains or the result would be negative); no automatic recalculation after adjustments or voids any more; BUG-071 (receipt posting locks products after the request-line locks; transfers, adjustments, issues and laundry value lines with the average read under the lock); BUG-072 (CSV cells fixed-point, `CostFormat`); unit-cost display `CostFormat.unit` / `format_unit_cost_currency` (`25`, `25.5`, `0.704`, `0.00000125`) | `db/migrate/20261123090000_*`, `app/services/inventory/average_cost.rb`, `product_cost_updater.rb`, `product_cost_recalculator.rb`, `app/lib/cost_format.rb` |
| Decision 17 audit | `inventory_average_cost_changes` (append-only trigger): product, previous / new average, on-hand before, quantity, unit cost, trigger (`receipt_posted`, `opening_balance_posted`, `document_voided`, `manual_recalculation`, `batch_replay`), source document, movement, operation reference, actor or `system = true`; written in the same transaction; an `AuditLog` entry `average_cost_changed` (fail-closed `log_audit!`) is written as well whenever an actor is known (the actor, else the business owner — the `Payroll::AutoGenerator` system-actor convention); a failure of either rolls the operation back | `db/migrate/20261123092000_*`, `app/models/inventory_average_cost_change.rb` |
| Decision 19 replay | `ProductCostRecalculator` is now a manual / batch tool only: posting-order replay with the posting rules; per-product savepoint; a negative running balance stops that product (no write, no record) and returns a `Diagnostic` (movement, balances, ordering, likely cause); other products continue | `product_cost_recalculator.rb` |
| P2 reservations, BUG-073, BUG-074 | `StockAvailability.removal_shortfalls` / `protect_reservations!` in transfers, adjustments (and so count approvals), voids / count reopens and laundry consumption — refusals name the approved issues; laundry consumption locked and checked inside its transaction; transfer posting audited (`post`); stock issue and transfer voids always audited in `DocumentVoider` | `stock_availability.rb`, `stock_transfer_poster.rb`, `adjustment_poster.rb`, `document_voider.rb`, `app/services/laundry/batch_material_consumer.rb` |
| P3 packaging structure | `product_packaging_levels` (position 1 – 4, partial unique indexes, immutability trigger, retire-only); deferred constraint triggers keeping `products.measure_amount` = innermost content and positions contiguous; `Inventory::Packaging::Configurator` (validation, retire rules, `SET CONSTRAINTS … IMMEDIATE`, audit `packaging_configured`); base unit locked once movements exist (model + form); Packaging editor and product-page card | `db/migrate/20261123091000_*`, `app/models/product_packaging_level.rb`, `app/services/inventory/packaging/configurator.rb`, `app/controllers/inventory/product_packagings_controller.rb`, views |
| P4 packaging ledger and posting | append-only `inventory_packaging_entries` (composite FK to the product's level); `Structure`, `Balance`, pure `Planner`, `EntryWriter`, posting `Session`; receipts (packages arrive sealed, base arrives loose), issues (strict packages, base loose-first with minimum opening), transfers (same packages arrive sealed; base arrives loose), adjustments (decrease loose-first; increase loose), laundry (loose-first), voids (inflow: free packages leave as packages, the rest as base; outflow: packages come back sealed, base loose; never resealed), approval warning (non-blocking, Decision 6) | `app/services/inventory/packaging/*`, posters |
| Document lines | `entered_quantity` + `packaging_level_id` on purchase request, receipt, issue and transfer lines (`PackagedLine`: base `quantity` derived, whole packages enforced); `entered_unit_price` / `entered_unit_cost` per entered unit (base price at 8 dp; line total from the entered figures); unit selector with live "= 50 pcs" hint on every line (`inventory/shared/_line_quantity`, `lib/packaging_units.js`); receipts from a request pre-filled in the purchase unit, with "+ Another unit" for mixed units on one request line; ordered / received / remaining shown in the purchase unit, truncated to 3 dp, with the base equivalent | models, `_item_fields` partials, show pages |
| Previews and effects | an approved / pending stock issue shows, per packaged line, what posting would do to the sealed packages from today's stock ("opens 1 carton · takes 3 boxes sealed") or the refusal it would meet; posted receipts, issues and transfers show their recorded packaging effect per warehouse | `packaging/issue_preview.rb`, `inventory/shared/_packaging_effects` |
| P5 stocktake | per-level counting on the counting screen (packages outside larger packages + loose); recorder derives the total and stores counted and recorded-at-entry breakdowns; approval classifies no-op / quantity-only / packaging-only / combined; packaging-only lines are zero-difference stock-count lines with `count_correction` entries and no movement (the exception is refused everywhere else); reopen negates the corrections | `stock_count_recorder.rb`, `stock_count_approver.rb`, `stock_adjustment_item.rb`, `_item_fields` |

### 21.2 Deviations from this design (deliberate)

1. **Audit store:** the Decision 17 record is a dedicated append-only table (always written, `system` flag, actor optional) plus an `AuditLog` mirror when an actor exists, instead of `AuditLog` alone — `AuditLog.actor` is required, and automated postings in a business without an owner would otherwise be impossible to audit.
2. **One unit per document line.** Mixed units are several lines (e.g. "1 carton" + "6 boxes", both pointing at the same request line); no composite per-line breakdown table (`inventory_line_breakdowns`) was added. Stocktake breakdowns are JSONB on `stock_count_items` (`counted_breakdown`, `system_breakdown`) and `stock_adjustment_items.packaging_differences`.
3. **Manual adjustments** are entered in the base unit only; their packaging effect is planned (loose-first / loose).
4. **No `costing_on` column and no period engine** (Decision 22). W2 makes the order of posting decide; `occurred_on` stays the document date.
5. **Void of a cost-bearing inflow** unblends at the void's time (inverse of the blend), leaving the average unchanged when no stock remains or the result would be negative; `last_purchase_price` is not rewound.

### 21.3 Not implemented (remaining)

* **P6 Unit Conversion document** (base-unit change with history) — the base unit is locked meanwhile, so no data can drift; a conversion needs its own approval.
* **P1.B accounting periods** (Decision 21's closed-period mechanics) — deferred by Decision 22.
* **Imports with packaging columns** (product, stock issue and count imports stay base-unit); **XLSX/CSV report columns per level**; barcode-to-level link.
* **Production read-only profile (G16)** — not run; rollout is not approved.

### 21.4 Migrations

`20261123090000_widen_inventory_cost_precision`, `20261123091000_create_inventory_packaging`, `20261123092000_create_inventory_average_cost_changes` — applied to the test database, and to **Development** on 2026-11-22 with the owner's explicit approval, one by one (`db:migrate:up VERSION=…`; no other migration ran; no inventory data changed — 2,148 movements and 176 products before and after; the new tables empty). **Production is not migrated.**

