# WorkPulse — Standard Component Migration Pattern

**Status:** standard, derived from the completed PermissionRole pilot (`cb9163e` … `5246f6c`,
`docs/architecture/permission-role-migration-plan.md`). It applies inside the six-domain modular monolith defined in
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

**Known spec pitfalls:**

* Don't name helpers after RSpec matchers (`change`).
* Trigger autoload before `const_source_location`.
* Keep spec constants inside a namespaced module, not a `describe` block.
* Use `examples?, ` when grepping results.

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
| **2. Workforce** | Fits | Same layout (`Workforce::` boundary; collapsed models). M5 is likely for request workflows; the User ≠ Employee stewardship constrains M7 (`users` stays in OA) |
| **3. Attendance & Payroll** | Fits | Strong existing coverage shortens M1; WF-defined contracts and `payroll.period_finalized` follow `module-boundaries.md` §12 inversion rules, not new HTTP |
| **4. Inventory & Purchasing** | Fits | Recorded IP → FS violations must be resolved via events in the owning steps; never fixed inside an unrelated component move |
| **5. Finance & Sales** | Fits, with care | Money paths: full security and characterization net, immutability (`Voidable`, ledger) asserted in M1; large controllers make M5 central |
| **6. Reporting** | Fits (read-only) | M2/M3 consume other domains' read interfaces; M5 rarely applies; enforcement asserts no writes |

The sequence and rules are consistent with `module-boundaries.md` §18 (interaction rules, notably rule 18 "moves are
mechanical") and §19 (dependency order). No new top-level domains are introduced.
