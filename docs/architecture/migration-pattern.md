# WorkPulse — Standard Component Migration Pattern

**Status:** standard, derived from the PermissionRole pilot (`cb9163e` … `5246f6c`,
`docs/architecture/permission-role-migration-plan.md`). It was validated by the Workforce Department + JobTitle pilot
(`0aa0066`) and the Workforce Performance pilot (`ae74dcc`); see `next-pilot-selection.md`. It applies inside the six-domain modular monolith defined in
`module-boundaries.md`: one Rails app, one database, in-process interfaces only, a strangler-style migration and no
HTTP between domains.

---

## 1. Purpose

Turn the PermissionRole pilot into a repeatable, evidence-driven procedure for moving any component of the remaining
domains behind its domain boundary:

* without changing behaviour, APIs, routes or the database
* with every step individually reversible
* without letting a new failure hide among existing ones

It is a **menu with rules**, not a fixed script. A component takes only the steps its evidence requires (§4).

---

## 2. PermissionRole pilot lessons

### What worked

| Practice | Evidence from the pilot |
|---|---|
| **Inventory before design, classified A–F** (internal / valid cross-domain / legacy / test-only / DB history / blocked) | Showed that only 3 cross-domain read paths existed (Laundry gate, onboarding policy, API login), so the boundary stayed tiny |
| **Locked decisions (D1–D4) written before implementation** | "No audit added", "OA-D3 not fixed", "R-L4 out of scope", "constant and table unchanged". Kept every step behaviour-preserving and stopped scope creep |
| **Characterization only for the gaps the migration touches** (G1–G7: 6 REQUIRED, 8 already covered, 5 optional) | 49 targeted examples instead of a broad rewrite. Pinned the contracts that later steps changed: `PermissionGrants` decisions, permission groups, String vs Symbol `can?`, API owner `[]` |
| **Baseline failing-ID file** (`permission-role-baseline-failures.txt`) and **ID comparison, never counts** | Every step proved "identical failing IDs". The 9–11 baseline failures in the same files (permission matrix, localization) could never mask a new one |
| **Delegate-first boundary** (`PermissionCatalog.group` returns the model's own array) | No second source of truth at any point; identity specs (`equal`) proved it |
| **One authoritative rule for duplicated logic, plus a parity spec** (`RoleAssignmentRule`; the role screen and employee form produce the same outcome) | Closed the main security risk (R-H2) with direct proof that both entry points agree |
| **Architecture spec with a reasoned allow-list, a stale-entry check and a probe test** | Blocks new cross-domain access with no new gems; the allow-list can only shrink; verified by planting a violation |
| **Physical move via a collapsed directory** (`app/models/organization_access/`, constant stays `PermissionRole`) | No caller, factory, association, migration or schema changes; one-line config; `git revert`-able |
| **Disposable-database verification with a hard `current_database` guard**, schema loaded in-process, per-migration `down`/`up` | Proved migration compatibility (14/15) without touching development, test or production, or the committed schema |
| **One commit per step, pushed after review** | Seven independent rollback points (`cb9163e`, `016415e`, `5f0468b`, `e4ca403`, `78be7c4`, `208b5b3`, `7d957a6`) |

### What was unnecessarily complex

| Issue | Lesson |
|---|---|
| The original plan listed 11 interfaces (I1–I11); only 2 boundary objects were justified (`PermissionCatalog.group`, `Authorization.granted_permissions`) | Design interfaces from **existing callers only** (§5 rule B) |
| `PermissionGrants` got a top-level compatibility alias (Step 4) used only by its own specs, then removed in Step 6 | An alias is needed only for callers you cannot update in the same commit (§5 rule G). Internal-only modules move with their specs in one commit |
| Two step numberings (plan sequence 1–7 vs pilot steps 1–7C) caused repeated cross-referencing | Use **one** numbering per component: the standard step IDs in §3 |
| Wrong counts ("16 migrations", "5 inline models") propagated through several documents until a probe corrected them | Every count in a plan must come from a reproducible command, recorded with the count |
| The first Step 7B run attempted all 299 migrations from zero, which the repository cannot replay (pre-existing defect MIG-1) | Check replayability first. Verify **only the migrations that reference the moved code**, from a schema-loaded disposable database (§8) |
| Several spec bugs came from test mechanics, not the code under test: a helper named `change` shadowing the RSpec matcher; `const_source_location` before autoload; constants defined in a `describe` block | Known pitfalls, listed in §7 |

### Confirmed by the Department + JobTitle pilot (first Workforce pilot)

* **M2–M5 can legitimately be empty.** M0 proved that no other domain calls the catalogues through code, so the
  pilot was M0 → M1 → M6 → M7 → M8 (decisions D-WF3/D-WF4). Boundary objects follow callers, not the sequence.
* **Domain-owned code can live in shared files.** The employee-profile part of `admin/users` belongs to Workforce
  but sits in Organization & Access files. It is handled as a reasoned allow-list exception, not moved.
* **A stewardship rule on a shared table can stay put.** `User#job_title_from_catalog` (D-WF1) is an enforced,
  documented exception; wrapping it would add coupling without removing any.
* **One collapse initializer per domain** (`organization_access_autoload.rb`, `workforce_autoload.rb`). M7 must
  update the boundary-spec allow-list paths in the same commit, because the stale-entry check enforces it.
* **Flaky baseline failures** are recorded in the baseline file with a `flaky` marker and a TD id (TD-PERF1):
  rerun to confirm, never counted as new, never fixed inside the pilot.

---

## 3. Standard migration sequence

Step IDs are fixed (`M0`–`M8`). A component's plan lists which steps apply and why the others are skipped.

| ID | Step | Purpose | Allowed | Not allowed | Required tests | Checkpoint | Rollback |
|---|---|---|---|---|---|---|---|
| **M0** | Scope, inventory, decisions | Know every reference and owner; lock behaviour decisions | Read-only analysis; plan doc; baseline failing-ID file | Any code change | Record the baseline: full-suite failing IDs | Docs commit (plan + baseline) | `git revert` (docs only) |
| **M1** | Characterization gaps | Pin every contract a later step will change | New specs only | Production changes; rewriting existing specs; asserting desired (future) behaviour | The REQUIRED gaps from M0, green against **unchanged** code | `test:` commit | `git revert` |
| **M2** | Boundary (delegating) | Give cross-domain callers a stable entry point | New boundary objects that **delegate** to the existing implementation | Copying rules or data; new source of truth; migrating callers | Focused boundary specs (delegation / identity) | `refactor:` commit | `git revert` (nothing calls it yet) |
| **M3** | Route cross-domain reads | Replace direct cross-domain reads with the boundary | One-line caller changes, identical results | Touching internal callers, writes, permission/scope semantics | Per caller: its focused specs, then the full relevant set; failing IDs identical | `refactor:` commit | `git revert` |
| **M4** | Relocate internal logic | Put domain logic in the domain namespace (`app/services/<domain>/`) | `git mv`, byte-identical body, caller prefix updates | Behaviour edits during the move; aliases without external callers | Equivalence (alias identity if one exists) + existing specs | `refactor:` commit | `git revert` |
| **M5** | Write operations into services | Move business rules out of controllers; one authoritative rule for duplicated logic | Small operation services (ids in, `Result` out, loaded inside `actor.business`); thin controllers | God services; changed redirects, flashes or statuses; new side effects (audit) unless decided | Service specs (valid / invalid / escalation / cross-business / owner), parity spec for duplicated paths | `refactor:` commit | `git revert` |
| **M6** | Cleanup + enforcement | Remove legacy access; block new coupling | Delete aliases with no remaining callers; architecture spec | Wrapping internal calls just to "hide" them | Architecture spec (+ probe proof), full relevant set | `chore:` commit | `git revert` |
| **M7** | Physical model move | Co-locate models with their domain | Collapsed `app/models/<domain>/`, `git mv`, byte-identical | Renaming constants or tables; namespacing a model that migrations or associations reference | `zeitwerk:check`, eager load, location spec, full relevant set | `refactor:` commit (config + move + allow-list path, atomic) | `git revert` |
| **M8** | Verification + documentation | Prove the move and close out | Disposable-database checks (approved); docs | Fixing pre-existing defects found on the way | As needed (§8) | `docs:` commit(s) | `git revert` (docs) |

---

## 4. Required vs optional steps

| Step | Classification | Condition |
|---|---|---|
| M0 | **REQUIRED** | Always |
| M1 | **REQUIRED** | Always (it may legitimately find zero gaps, and says so) |
| M2 | **ONLY WHEN NEEDED** | At least one **cross-domain** caller reads the component's internals |
| M3 | **ONLY WHEN NEEDED** | M2 was done |
| M4 | **OPTIONAL** | Internal logic lives outside the domain namespace and has a clear owner |
| M5 | **ONLY WHEN NEEDED** | Business rules sit in controllers or views, or the same rule exists in more than one place |
| M6 | **REQUIRED** (enforcement) / **ONLY WHEN NEEDED** (cleanup) | Enforcement always; cleanup only if legacy access or aliases exist |
| M7 | **OPTIONAL** | Physical co-location is wanted and the constant can stay unchanged (§5 rules E, F) |
| M8 | **REQUIRED** (docs) / **ONLY WHEN NEEDED** (database verification, §8) | Database verification only when constants referenced by migrations move, or the database is touched |

### Fast track (from Pilot 3 onward)

The fast track groups the standard steps; it is **not** a second numbering. Plans name both labels.

| Fast-track step | Standard step IDs |
|---|---|
| M0 Fast inventory | M0 (inventory, ownership, cross-domain refs, direct writes, cycles, security paths, gaps, baseline) |
| M1 Characterization | M1 (only missing coverage) |
| M2 Boundary | M6 enforcement (+ M2 only when a real cross-domain caller exists) |
| M3–M5 Migration | M2–M5 (only where evidence requires) |
| M6 Physical organization | M7 (collapsed folder; optional) |
| M7 Verification / M8 Docs | M8 |

**Default:** use the fast track when M0 finds no real cross-domain code callers (validated by both Workforce
pilots). In that case fast-track M2 + M6 + M7/M8 may be a single commit after M1. When M0 finds real cross-domain
callers (as in PermissionRole), run the boundary and routing steps (standard M2–M5) explicitly.

**Pilot 3 (Workforce Performance) lessons.**

* **M0/M1 can reveal real production defects.** Fix each genuine defect in its own approved commit **before**
  pinning behaviour:
  * security gaps first (SEC-P3-1, cross-business references)
  * crashes that block characterization (PERF-D1)
* **Low-impact defects can be pinned** as labelled known defects instead (PERF-D2).
* **Same-business validations can invalidate factory defaults.** Make factories build same-business data, and keep
  cross-business data explicit in security specs.
* **Each new domain group extends its domain's existing boundary spec and allowed directories**, rather than adding
  a new spec.

---

## 5. Boundary rules (decision rules A–L)

| Rule | Decision |
|---|---|
| **A. Create a domain boundary** | When code **outside** the owning domain reads or calls the component's internals (constants, associations, internal services). Not for internal callers. |
| **B. Introduce a service/interface** | Only for a **concrete existing caller** (or the caller that the very next step migrates). One method per real need. No speculative interfaces. Operation services (M5) when a controller holds business rules or a rule is duplicated. |
| **C. Route existing reads through the boundary** | Every **cross-domain** read, in one step, with identical results proven by characterization. Internal reads stay direct. |
| **D. Move a service** | When it is owned by the domain and lives outside the domain namespace. Move it verbatim (`git mv`) and update callers in the same commit. |
| **E. Physically move a model** | When co-location adds value **and** the move can keep the constant and table unchanged (collapsed directory). Never as a prerequisite for anything else. |
| **F. Keep a model top-level** | When historical migrations, associations, factories or many specs reference the constant, which is typical for every existing model. Domain ownership is expressed by location (collapsed dir) and enforcement, not by the constant's namespace. |
| **G. Use a compatibility alias** | Only when callers outside the commit's control still use the old name (another domain mid-migration, external scripts, data migrations). The removal step is written down when the alias is created. Never for callers you can update in the same commit. |
| **H. Do NOT use a wrapper** | When the caller is internal to the same domain; when the call **is** the rule (e.g. policies calling `PermissionGrants`); when the wrapper would only rename a method; when nothing outside the domain needs it. |
| **I. Direct access is acceptable** | Inside the owning domain; for preloads (`includes(:association)`) that feed a public interface; for UI-shell and admin screens owned by the domain; for frozen history (migrations, seeds). Each exception is listed with a reason. |
| **J. Block direct access with an architecture spec** | Once the boundary exists and cross-domain callers are routed (end of M6). The spec scans code (comments ignored), keeps a reasoned allow-list, fails on stale entries, and is proven with a probe. |
| **K. Require database verification** | When a constant referenced by migrations moves; when a model's file/loading changes; or when any table, column, index or foreign key is involved (that is its own phase, §8). |
| **L. Existing technical debt stops a migration** | Only if it **blocks the step's proof** (the behaviour cannot be characterized, the step cannot be verified, or the debt is a security issue in the touched path). Otherwise record it (with an ID) and continue; never fix it inside the migration. |

---

## 6. Cross-domain rules

**Internal domain access** = code inside the owning domain (its models, services, policies, controllers, views and
jobs) using its own internals directly. **Cross-domain access** = any other domain touching those internals. It must
go through a public interface, an event, or an explicitly allow-listed exception.

| Concern | Internal | Cross-domain |
|---|---|---|
| **Reads** | Direct (models, constants, associations) | Via the owner's public interface (e.g. `PermissionCatalog.group`, `Authorization.granted_permissions`). Read-only preloads are allowed when they feed a public interface |
| **Writes** | Through the domain's own services | Never direct. Call the owner's public operation, or publish an event the owner consumes (`module-boundaries.md` §18 rules 3–4) |
| **Authorization checks** | Policies may call the domain's rule modules directly | `user.can?` / `user.scope_for` / `ApplicationPolicy` helpers only; never evaluate another domain's permission data |
| **Associations** | Allowed | Allowed as **references** (`belongs_to`, read-only traversal) when documented; inverse `has_many` into another domain is a recorded violation to remove |
| **Callbacks** | Allowed within the aggregate | Must not write another domain's tables; use events |
| **Services** | Called directly | Only the owner's public services/interfaces; never its internal helpers |
| **Controllers** | Thin: authorize → service → respond | Must not query another domain's models for business decisions; use its interface |
| **Policies** | Own rules + shared Pundit helpers | No re-implementation of another domain's visibility |
| **Queries** | Free within the domain | Via read interfaces; Reporting may read across domains (read-only) |
| **Jobs** | Run the domain's services | Trigger other domains only via events or public interfaces |

Every boundary resolves records inside the acting business (no trusted `business_id`), and has cross-business specs.

---

## 7. Testing standard

Minimum safety net **before** any production change (M0–M1):

| Layer | Requirement |
|---|---|
| **Baseline** | Full-suite failing **example IDs** recorded in a committed file before M1 |
| **Characterization** | Every contract a later step changes is pinned against unchanged code (current behaviour, including known defects, labelled as such) |
| **Security** | Existing security specs for the area green; cross-business, escalation, owner and self-modification cases exist for every touched write path |
| **Request / API** | Response shape, ordering, status codes, flashes and redirects of every touched endpoint pinned (e.g. login `permissions`, owner `[]`) |
| **Policy** | Allow/deny per permission and scope for touched policies |
| **Service** | For each new service: valid, invalid, escalation, scope escalation, cross-business, owner, "no unintended side effect" (e.g. no audit if decided so) |
| **Parity** | When duplicated logic is consolidated: one spec proving all entry points reach the same outcome |
| **Architecture** | Boundary spec (M6) and location spec (M7) |

**Pre-existing failures:**

* Never fixed inside a migration.
* Compared **by ID** before and after every step. Any ID not in the baseline file is a new failure, and the
  migration stops (§10).
* Counts are reported but never used as the criterion.
* A failure outside the baseline stops the work. If investigation proves it is data-dependent flakiness (passes on
  repeated reruns, root cause identified), record its IDs as `flaky <id>` with a TD id after review. Never silently
  ignore it.

**Known spec pitfalls:**

* Don't name helpers after RSpec matchers (`change`).
* Trigger autoload before `const_source_location`.
* Keep spec constants inside a namespaced module, not a `describe` block.
* Use `examples?, ` when grepping results.
* When building roles in specs, satisfy permission dependencies (e.g. `manage_evaluation_templates` needs
  `view_performance_dashboard`), or the factory raises.
* Create lazily-defined records (`let`) before a `change` block that counts them.
* Find the real code path before asserting an error. Onboarding approval is refused by the revision's
  `valid_as_employee`, not by the later `User` save.
* Do not assert ordering across mixed case; `order(:name)` follows the database collation.

---

## 8. Database standard

**SAFE WITHOUT DATABASE CHANGES** when all of these hold:

* The constant name and table name are unchanged.
* Associations, foreign keys and `dependent` options are unchanged.
* No `type` (STI) or polymorphic `*_type` column stores the class name. Check with a read-only query.
* Files move byte-identically (Zeitwerk collapse keeps top-level constants).

Under those conditions, `db:prepare`, `db:test:prepare` and `maintain_test_schema!` (which all load `schema.rb`) are
unaffected.

**Requires a separate database phase** (its own plan, approval and commits, never mixed into a domain move) when any
of these is needed:

* a table, column, index or foreign-key change
* a rename of a constant stored in data (STI or polymorphic)
* a data backfill or correction

**PermissionRole lesson:**

* Moving `app/models/permission_role.rb` → `app/models/organization_access/permission_role.rb` with the folder
  collapsed kept `PermissionRole` / `permission_roles` and all associations.
* 15 historical data migrations call the live model. They keep working only because the top-level constant stays.
  That is why rule F prefers top-level constants.
* **Fresh-database verification:**
  * Don't replay all migrations from zero unless the history is known to be replayable.
  * Load `db/schema.rb` into a **disposable** database, with a hard `current_database` guard and nothing written to
    the repository.
  * Seed minimal data, then run `down`/`up` only for the migrations that reference the moved code.
  * Drop the disposable database afterwards.
* **Pre-existing migration defects** (MIG-1 duplicate `phone_number`; MIG-2 POS/Sales schema drift) are recorded as
  separate technical debt. They don't become part of a domain migration because:
  * fixing them changes migration history or schema, a different risk class from a behaviour-preserving move
  * they are unrelated to the component's contract
  * mixing them would make the domain commit non-revertible and its verification ambiguous

---

## 9. Commit / checkpoint standard

* **One commit per step** (M0…M8). Each commit leaves the app fully working and is pushed only after review.
* **Prefixes:** `test:` (M1), `refactor:` (M2–M5, M7), `chore:` (M6), `docs:` (M0, M8).
* **What may share one commit:**
  * Changes that cannot work apart. M7 combines the autoloader config, the `git mv` and the allow-list path update,
    because each alone breaks loading or the architecture spec.
  * A move together with its caller updates.
  * A step together with its own focused specs and status doc section.
* **Never mixed in one commit:**
  * Behaviour changes with structural moves.
  * Database work with code moves.
  * Pre-existing defect fixes with migration steps.
  * Two migration steps.
* **Commit body:** what moved and what it now delegates to; the decisions honoured (D-numbers); "no route/API/schema
  changes".
* **Before every commit:** `git diff --check`, `bin/rails zeitwerk:check`, the full relevant set with failing-ID
  comparison, and a scope review of the diff (only intended files).

---

## 10. Stop conditions

Stop and report (no workaround, no improvisation) when any of these happens:

* A failing example ID that is not in the baseline file.
* Any change in security behaviour: cross-business access, permission or scope escalation, owner or
  self-modification rules.
* An unexpected `db/schema.rb` diff, or a step that suddenly needs a migration or a schema change.
* An API contract change: shape, ordering, status, auth behaviour.
* Web behaviour change: route, redirect, flash, status.
* Unclear ownership of a model, table or rule, or a newly discovered circular dependency (`module-boundaries.md` §13).
* Database isolation cannot be guaranteed for a verification.
* A behaviour cannot be characterized safely (no stable observable outcome).
* The step would require touching another domain, the User ≠ Employee split, or a locked decision.
* `zeitwerk:check` or eager-load failure.
* A compatibility bridge becomes necessary that has no documented removal step.

---

## 11. Anti-patterns (do not repeat or mandate)

* **Speculative interfaces:** designing an interface list up front instead of deriving it from callers (I1–I11 →
  only 2 used).
* **Aliases for code you control:** the `PermissionGrants` alias served only the module's own specs.
* **Wrappers around internal calls**, to "hide" a call that is already inside the domain or that *is* the rule.
* **Moving before callers are ready:** relocating a model or service while cross-domain callers still use it
  directly.
* **Namespacing models that history depends on** (`OrganizationAccess::PermissionRole` would have needed a
  permanent alias).
* **Same folder structure everywhere:** apply M7 only where it helps; logical ownership plus enforcement is
  sufficient.
* **Over-testing implementation details:** assert contracts (results, identity, status codes), not internals.
* **Fixing unrelated debt mid-migration**, or "helpful" behaviour changes (auditing, OA-D3) inside a structural step.
* **Uncounted claims:** every number in a plan needs a reproducible command.
* **Two step numberings** for the same work.
* **Replaying all migrations from zero** as the default verification.

---

## 12. Next-pilot selection criteria

Score each candidate component (not a whole domain) from evidence, 1 (best) to 3 (worst) per criterion. Prefer the
lowest weighted total. Ties go to the candidate higher in the dependency order (`module-boundaries.md` §19).

| Criterion | Measure (reproducible) | Weight |
|---|---|---|
| Coupling | Count of cross-domain code references (inventory command) | 3 |
| Callers | Number of files calling the component | 2 |
| Cross-domain dependencies | Edges in §12.2 involving the component, especially recorded **violations** | 3 |
| Security risk | Touches authorization, money or personal data? Existing security specs? | 3 |
| Business criticality | Money movement / payroll / custody = high | 2 |
| Test coverage | Examples covering it; characterization gaps found in M0 | 2 |
| Database complexity | Tables, STI or polymorphism, migrations referencing its constants | 2 |
| Circular dependencies | Part of a cycle or an upstream inversion (§13)? | 3 |
| Size | Lines and files to move | 1 |
| Rollback difficulty | Can every step be a single `git revert`? | 2 |
| Baseline noise | Pre-existing failing IDs in its spec files | 1 |

**Disqualifiers** (choose another pilot):

* the candidate requires a database phase
* the candidate requires the User ≠ Employee split
* the candidate sits on an unresolved circular dependency
* there is no stable characterization path

---

## 13. Six-domain alignment

The pattern works per **component inside a domain**. It does not change the domain model.

| Domain | Fit | Notes |
|---|---|---|
| **1. Organization & Access** | Proven (PermissionRole) | Boundary: `app/services/organization_access/` (`OrganizationAccess::`); models: collapsed `app/models/organization_access/` |
| **2. Workforce** | **Proven** (Department + JobTitle: collapsed `app/models/workforce/`, enforcement spec, no boundary object) | `Workforce::` boundary (`app/services/workforce/`) only when a real cross-domain caller appears; collapsed models. M5 is likely for request workflows; the User ≠ Employee stewardship constrains M7 (`users` stays in Organization & Access) |
| **3. Attendance & Payroll** | Fits | Strong existing coverage shortens M1; WF-defined contracts and `payroll.period_finalized` follow `module-boundaries.md` §12 inversion rules, not new HTTP |
| **4. Inventory & Purchasing** | Fits | Recorded IP → FS violations must be resolved via events in the owning steps; never fixed inside an unrelated component move |
| **5. Finance & Sales** | Fits, with care | Money paths: full security and characterization net, immutability (`Voidable`, ledger) asserted in M1; large controllers make M5 central |
| **6. Reporting** | Fits (read-only) | M2/M3 consume other domains' read interfaces; M5 rarely applies; enforcement asserts no writes |

The sequence and rules are consistent with `module-boundaries.md` §18 (interaction rules, notably rule 18 "moves are
mechanical") and §19 (dependency order). No new top-level domains are introduced.

---

## 14. Milestone 2 — Attendance & Payroll (application notes)

**Status:**

* M0 done (at `c054fa3`).
* Security hardening done (SEC-M2-1, -2, -3, -4 and -9: `28b2100`, `ca66c43`, `3d9127e`, `a384319`).
* **Pilot 1 (Biometric Device + PunchService) M1 is complete** (`1024ffb`: 59 examples, 0 new failure IDs).
* **Pilot 1 is COMPLETE:** M6 `8eac847`, M7 `bea07f8` (models moved to the collapsed
  `app/models/attendance_payroll/`), M8 done.
* **Pilot 2 (Employee Obligations) is COMPLETE:**
  * security precondition `869cadd`;
  * AP-D4 / AP-D5 fixes `6177e8b` / `b6d4526`;
  * M1 `c255f5e`, M6 `9298ced`, M7 `77239ce`, M8 docs.
  * See `next-pilot-selection.md` §17.
* **Milestone 2 — Finance & Sales Expenses** is selected (standard path). M0 is done; SEC-M2-12 (`6b4d300`),
  FS-D1 (`f88e022`) and FS-D2 (`94c4dce`) are fixed; **M1 is complete** (`98edd8e`). The standard path is kept
  (the AP → FS write and cycle F3 remained). **M2 `4b94668`, M3 `d009f0d` and M4 `0ca2dc5` are complete:** the
  AP-defined, FS-implemented `Payroll::FinalizationEffects` contract carries the payroll-computed insurance cost,
  Finance owns the expense, `Payroll::InsuranceExpenseGenerator` is removed and **cycle F3 is eliminated**. M5 was
  evaluated as not needed. M6 `ddaceb1` (boundary), M7 `ee47554` (8 models into the collapsed
  `app/models/finance_sales/`) and M8 are done: **Pilot 3 is COMPLETE** (`next-pilot-selection.md` §18.8). FS-D3
  is recorded as open debt.
* **Pilot 4 (Attendance & Payroll Penalty Rules) is COMPLETE** (standard path, `feature/pilot-4-penalty-rules`):
  M0 `b73fc34`, M1 `3efb46b`, M2 `40e5ed0`, M3 `4d7ae92`, M4 `a2ae7aa`, M5 not needed, M6 `3fd9ba2`, M7 `a3b6463`,
  M8 docs. The WF `Shift` nested write into AP `penalty_rules` is inverted through the Workforce-defined
  `Shifts::PenaltyRuleSettings` contract (`next-pilot-selection.md` §19.11–§19.12).
* **Pilot 5 (Organization & Access ↔ Workforce membership contract) is COMPLETE** (standard path,
  `feature/pilot-5-membership-contract`): M1 `114f771`, M2 `69031c1`, M3 `5d6b454`, M6 `1b5cd65`, M8 docs; M4, M5 and
  M7 not needed. The access scopes read membership only through the OA-defined `OrganizationAccess::MembershipProvider`
  (Workforce implementation), with four classified exceptions (`next-pilot-selection.md` §20).
* **Merged on `main` since (verified against Git and GitHub on 2026-10-22; `next-pilot-selection.md` §43):**
  * Pilot 5 and Pilot 6 (Inventory & Purchasing Supplier) — PR #30 (`24f1573`); Pilot 7 (Product Catalogue) — PR #31
    (`4655d18`); Pilot 8 (Employee Insurance Profile) — PR #32 (`a9f8ff3`); Pilot 9 (Request Permission Payroll
    Effects) — PR #33 (`82cce16`); Pilot 10 (Punch Correction) — PR #37 (`7d2a8c8`); Pilot 11 (Reporting: laundry
    cost) — PRs #43 / #44 (`96cc194`), close-out PR #45.
  * Pilot 12 (POS terminals) with Batches R (Reporting read-only), W (warehouse access) and A (advance payment) and the
    standalone security / concurrency fixes — PR #57 (`bc6682b`); Pilot 12 close-out — PR #59 (`17fbcce`).
  * Batch V (request-validation reads) — PR #58 (`872e55f`); Batch S (goods-receipt payment writes) — PR #60 (`ec8ae59`).
  * Work committed locally after `ec8ae59` (S2, the dependency inventory, F2, SAL) is **not** listed here until merged.

See `next-pilot-selection.md`, "Milestone 2 — Attendance & Payroll", §5.1–§5.2 and §13. Nothing below changes the standard
sequence (§3) or the rules (§5).

* **The fast track still applies, behind a security precondition.** Pilot 1 (Punch capture channel) has no
  cross-domain callers, so its plan is M0 → security fix → M1 → (M6 + M7 + M8). The fix is a separately approved
  `fix:` commit, not a migration step (the Pilot 3 / SEC-P3-1 rule).
* **Extra M0 check for every AP group.** A policy existing does not prove that it is called:
  * List each controller's `authorize` / `policy_scope` calls, and treat a controller with **none** as a security
    finding.
  * `Admin::BaseController#require_admin_access!` accepts 13 permissions (including `view_*`), so it is **not**
    an authorization rule for any single action.
* **M0 security probes stay out of the repository.** Proving a defect with a throwaway request spec run from a
  scratch location (transactional test DB) gives evidence without adding specs before M1.
* **The first AP physical move creates the domain's collapsed directory and initializer.** As with Workforce
  (§2), the AP boundary and location specs are created once and extended by later AP groups.
* **Security hardening is a phase between M0 and M1, never part of a migration step.**
  * **Why separate:** a fix changes behaviour; a migration step must not (§9).
  * **Commit order:** the fixes land as their own `fix:` commits, one per finding, or one for findings that cannot
    be closed apart. They come **before** M1, so characterization pins the corrected behaviour.
  * **Pre-fix proof:** every regression spec is run once against the pre-fix code, so its attack cases are proven to
    fail before the fix.
* **Fix the whole write surface, not only the reported controller.** Fixing SEC-M2-3 (penalty-rule controller)
  exposed SEC-M2-9: the same records were writable through another controller's nested attributes
  (`Shift` → `penalty_rules_attributes`). When closing an authorization gap, list every path that writes the same
  table (nested attributes, services, other controllers) before declaring it closed.
* **A rescued 404 does not carry the signed-in test session into the next request.** In request specs, keep
  requests that end in a 404 one per example (Devise test sign-in + exceptions app); otherwise the follow-up
  request is redirected to sign-in and the spec tests nothing.
* **M1 pins deferred security behaviour as-is, labelled with its finding ID.** Pilot 1 M1 pinned punch-log
  visibility (deferred SEC-M2-8) as the current contract, with the ID in the spec. The later fix then changes a
  known, named expectation instead of silently breaking an unlabelled one.
* **Defects found by characterization are pinned, not fixed.** AP-D3 (a punch updates a soft-deleted attendance
  record) is asserted as current behaviour and recorded as technical debt. Fixing it needs its own approved
  `fix:` commit, outside the migration (the PERF-D2 precedent).
* **Probe before asserting.** Edge behaviour (timestamp formats, spam-window membership, token override) was
  observed with throwaway probes first, so every characterization expectation records observed behaviour, not
  assumed behaviour.
* **Fast track validated for Attendance & Payroll (Pilot 1).**
  * **When:** a component with **no cross-domain business callers, no cross-domain writes and no circular
    dependencies**.
  * **Sequence:** M0 → M1 → M6 → M7 → M8, the same as both Workforce pilots.
  * **M2–M5:** skipped only because evidence proved them unnecessary. The M0 inventory found no cross-domain
    caller, and the M6 reference classification confirmed it; the services were already in their domain
    namespace, and no business rule sat in a controller.
  * **Not a shortcut:** if M0 or M6 finds a real cross-domain caller, the standard M2–M5 steps apply.
* **M6 comes before M7, in separate commits.**
  * **Why:** boundary enforcement classifies every reference while the files are still in their old place, so a
    physical move cannot hide an unknown cross-domain dependency.
  * **Effect on M7:** M7 then only updates the allow-list paths, and its failing-ID comparison against the
    pre-move commit proves the move changed nothing.
  * Pilot 1 did M6 alone (`8eac847`), then M7 (`bea07f8`).
* **The collapsed-folder pattern now holds for three domains.** Organization & Access, Workforce and Attendance &
  Payroll each use one one-line collapse initializer per domain folder, with top-level constants and unchanged
  tables.
* **Faker apostrophe names are a recurring flaky-test cause** (TD-PERF1, TD-FIN1, TD-OA1). A new failure ID
  outside the baseline still stops the work, as `§7` requires. Investigate it, prove it is data-dependent with
  isolated reruns and an untouched code path, then record it as `flaky` with a TD ID **after review**. Never
  rewrite the spec to hide it inside a migration step.
* **Pilot 2 confirmed the fast track for a money sub-area coupled to its own domain's core.**
  * **The coupling:** Employee Obligations are coupled both ways to the payroll core. Payroll deducts them, and the
    obligation services rebuild payroll.
  * **Why the fast track still fit:** that coupling is internal to Attendance & Payroll. M6 lists it as AP-internal
    allow-list entries, not exceptions, so no boundary object was needed.
* **Correctness defects found in M0 are fixed before M1, like security defects**, when they affect money:
  * AP-D4 and AP-D5 got their own `fix:` commits and regression specs.
  * M1 then characterized the corrected behaviour instead of pinning broken payroll.
  * Defects with no financial impact can still be pinned (the AP-D3 / PERF-D2 precedent).
* **A met M5 condition does not force M5.** When the needed change is behavioural (audit, reason, recalculation), it
  is recorded as technical debt or fixed in a separate `fix:` commit. M5 inside a migration may only move logic
  without changing behaviour.
* **Reuse the domain's existing collapse.** The second AP group needed no new initializer: one per domain folder,
  however many groups move into it.
* **Break a cross-domain cycle by splitting the service by data ownership, not by moving it whole** (Finance &
  Sales Expenses M4).
  * **The trap:** a service that reads the caller's data and writes the callee's data cannot simply move to the
    callee. Moving `Payroll::InsuranceExpenseGenerator` into `Finance::` unchanged would have made Finance read
    payroll entries and shift assignments, reversing the cycle instead of removing it.
  * **The rule:** the caller computes what it owns and passes it as plain data in the contract
    (`employer_insurance_total`, `employer_insurance_by_branch`); the callee owns every write (records, category,
    allocations, numbering, void, audit). Check it with a source scan on both sides.
* **M2 → M3 → M4 as three small commits keeps each step provable.** M2 added the contract with an adapter that
  delegates to the old code; M3 routed the callers; M4 moved the logic. Each step kept the same failure IDs, and M4
  only had to change stub targets and payloads in specs, never expectations.
* **Remove the old class in M4 when nothing references it.** No compatibility wrapper without a concrete caller
  that needs it; leave a one-line provenance comment in the new code instead.
* **M5 is evaluated, not assumed.** Once M4 leaves every piece as a service in its owning domain and no controller
  holds the logic, record M5 as not needed with that evidence.
* **Guard what a name means, not the bare word** (Finance & Sales Expenses M6). `expenses` is also a profitability
  metric key and a local variable, so the boundary guards constants, `.expenses`-style collection calls,
  association macros and the multi-word table names, and ignores `t(...)` keys. Pin both sides with self-tests:
  real references must match, policies / routes / permissions / metric keys must not.
* **A read-only exception needs a write check over its whole area.** The Reporting read-only check first covered
  only listed files, and a write planted in a new file under `finance/dashboard/` passed. Probe every rule with a
  planted file, including new files in allowed directories.
* **A domain's first physical move creates its collapse initializer, approved before it is written** (Pilot 3 M7).
  Without the collapse, Zeitwerk expects a namespace, which a move must not introduce. In the location spec, sweep
  every non-polymorphic association in the app, not only a hand-written list.
* **Move the pilot's associated group, not the whole domain.** M7 moved the 8 Expenses models the pilot scoped;
  other Finance & Sales models wait for their own pilot.
* **After fixing a defect, search for the same pattern elsewhere.** FS-D2 (case-sensitive `find_or_create_by!` on a
  case-insensitively unique name) recurred in POS fee generation (FS-D3). A sibling outside the pilot's path is
  recorded as debt and fixed in its own approved `fix:` commit, never inside a migration step.
* **A documented flaky ID is compared against the documented baseline,** not only against the previous run: TD-OA1
  appeared in M6/M7 and passed at M8, with the same Faker-apostrophe cause and isolated passes each time.
* **The contract's owner follows the dependency graph, not the brief** (Pilot 4 M2). When an upstream domain
  (Workforce) needs behaviour that a downstream domain (Attendance & Payroll) owns, the upstream domain defines the
  contract and the downstream implements it, wired at boot (`module-boundaries.md` §12.1, §18 rule 5) — the same shape as Pilot 3 with the roles
  reversed. A downstream-owned interface called from upstream only turns a model write into a service call and keeps
  the cycle. Check the requested ownership against `module-boundaries.md` §12.1 before writing code, and ask when they
  disagree.
* **Replacing `accepts_nested_attributes_for` without changing behaviour** (Pilot 4 M4): stage rows on the
  association in the owning domain and declare `autosave: true` on the inverse association (what nested attributes
  enabled), so validation, errors on the parent, `_destroy` and the single transaction stay as they were; keep the form's
  field names with `fields_for :<name>_attributes, record, index:`. Prove it with before/after HTML snapshots of the
  form, including the 422 re-renders.
* **Decide each optional step with a short evidence review** (Pilot 4 M5, M7): M5 was not needed (no rule in a
  controller or view, nothing duplicated; audit is behavioural); M7 was done because the domain folder and collapse
  already existed and only one allow-list path depended on the file. Neither "the pattern has the step" nor "it is
  optional" is a reason on its own.
* **An unexpected read can be an explicit exception when it is pinned to its shape** (Pilot 4 M6): the branch staff
  view's rule count rides on an already documented exception, so the spec allows exactly its two read shapes (preload
  and `.size`) instead of the whole file, and a widened read fails.
* **Commit the focused set with its baseline** (applied from the milestone review): Pilot 4's 78-file set and its
  rerun command live in `attendance-payroll-penalty-rules-baseline-failures.txt`, so every step's comparison was
  reproducible from the repository.
* **Verify an earlier review's dependency claims in code before planning** (Pilot 5 M0): the closeout review said both
  scopes called `BranchMembership`; `BranchScope` in fact queried `ShiftAssignment` directly, duplicating it. The
  M3 routing then removed a duplicate instead of only re-pointing a call.
* **Keep a contract's return shape when performance depends on it** (Pilot 5 M2): `current_member_ids` returns a
  chainable relation used as `IN (subquery)`; pin the shape (type, model, `select_values`, identical SQL) in M1 and the
  contract spec, so routing cannot quietly materialize id lists.
* **Prove routing with a planted provider, not equal output** (Pilot 5 M3): swapping the registered provider for a fake
  whose answers differ from the real data shows the caller actually goes through the contract; equal results alone
  would also pass with a direct query.
