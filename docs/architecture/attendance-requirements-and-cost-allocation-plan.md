# Attendance Requirements, Central & Floating Employees, and Cost Allocation — Business Rules & Implementation Plan

**Status:** owner-approved primary roadmap (revision 17, approved 2026-11-10; see revision 18). The approval of the
roadmap is **not an authorisation to implement**: each phase in §19.10 needs its own explicit owner authorisation,
and production work, migrations and deployments need separate approval. Nothing here describes current behaviour
unless labelled **[C]**.

**Baseline:** `origin/main` `7585f16` (merge of PR #114). PR #110 (`5c4e145`), #114 (`7585f16`) and #115 (`aab5554`)
merged. Every code reference below was re-read at this commit.

**Revision 2 (2026-11-05):** adds the owner-approved decisions L1–L9 (§2 L): the daily-paid attendance invariant
(former Q2), its concurrency, history, backfill, leave, conversion and rejected-attempt audit rules, and the legacy
schedule interpretation (former Q1). The §3.6 evidence was read at the same baseline. Nothing in this plan is
implemented.

**Revision 3 (2026-11-05):** adds the owner-approved decisions L10–L17 (former Q15–Q20): explicit HR selection of
the requirement at employee creation, the all-employee backfill with an explicit Not Reviewed state and its
effective-date precedence, the Not Reviewed rule for daily profiles, the rejected-attempt audit transaction and
failure handling, Workforce-owned leave management, the monthly-paid leave policy, and Historical Violations.
Detailed technical points these decisions leave open are listed as Q21–Q28 (§5).

**Revision 4 (2026-11-05):** adds the owner-approved decisions L18–L25 (former Q21–Q28): mandatory employment start
date, backfill evidence rules, the durable rejected-attempt audit retry, leave approved after a payroll lock, the
business-level annual-leave entitlement policy, the unpaid-leave deduction formula, the Historical Violation review
roles, and the HR exception list. Points these decisions leave open are listed as Q29–Q33 (§5). The transition
deadline remains unresolved (Q3).

**Revision 5 (2026-11-05):** adds the owner-approved decisions L26–L30 (former Q29–Q33): annual-leave balance rules
(tiers, tier transitions, two-decimal precision, carry-over and its expiry, termination settlement), leave approval
routing and cancellation, the payroll-period unpaid-leave deduction, the audit-failure alert channel, and the
Historical Violation permissions. Points these decisions leave open are listed as Q34–Q38 (§5). Q3–Q14 are
unchanged and unresolved.

**Revision 6 (2026-11-05):** adds the owner-approved decisions L31–L35 (former Q34–Q38): the full annual-leave
entitlement policy (anniversary leave year, proration, tier split, no negative balances, carry-over batches, FEFO
consumption, service date, accrual during unpaid leave), the per-employee finalization block for unreliable
unpaid-leave deductions, configurable leave types with fallback approvers and the self-approval ban, audit-failure
ownership, escalation, dashboards, de-duplication, resolution and manual retry, and the historical payroll correction
workflow (Finance Approvers, Super Admin fallback, rejection and resubmission). Remaining details and design
dependencies are listed as Q39–Q45 (§5), each with a conservative recommendation that is **not** an approved
decision. Q3–Q14 are unchanged and unresolved. Nothing in this plan is implemented.

**Revision 7 (2026-11-05) — architecture review:** adds §18. Every open question is classified (§18.1) as an owner
business decision, a technical decision, or both. Technical decisions are made here as **[T]** recommendations, so
the owner is no longer asked about implementation details. Ten architecture gaps are analysed (§18.2), phase
readiness is assessed (§18.4), and the owner decisions still needed are consolidated (§18.5). No approved decision
(L1–L35 and earlier) is changed. Two earlier **[P]** statements are corrected:
(1) §6.6 assumed writing the durable record and enqueuing its retry job commit atomically, but production Solid
Queue writes through its own `queue` connection;
(2) the baseline has moved: `origin/main` is now `3e01ac3` (PRs #116 and #117, Salary Payment Hold), which changes
files this plan cites (`Payroll::Approver`, `Payroll::Reopener`, `db/schema.rb`). Evidence must be re-read on the new
baseline before implementation (§18.4).

**Revision 8 (2026-11-05) — owner decisions:** records the owner's approval of D1–D8 (§2 M, §18.6):
* D1: the HR review deadline and the platform roles;
* D2: the central and floating cost label;
* D3: one business-wide holiday calendar;
* D4: backdating refused once a payroll period is Under Review;
* D5: no cross-branch overlap for new regular assignments, and the monthly absence formula with a Parity Report;
* D6: the termination leave payout;
* D7: the principle for held employees. It approves the business principle only; the R7.0 design still needs its
  own approval;
* D8: daily-paid leave, carry-over expiry and correction resubmissions.

They close Q3's review deadline, the business part of Q4, Q9–Q12, Q39, the business part of Q40, Q41,
Q42 (a)/(b), Q44 and Q45 (d). Still open: Q3's legacy-schedule end date and five interpretation points (Q46). The
contradiction check is in §18.6.2, and no approved decision is reversed. Earlier revision notes describe the plan as
it stood at that revision. Nothing in this plan is implemented.

**Revision 9 (2026-11-06) — remaining owner decisions:** records the owner's approval of D9–D14 (§2 N, §18.7):
* D9: the L9 (1) legacy-schedule exception ends at the end of the second complete Payroll Period after R4 is
  deployed, separately from the Not Reviewed deadline;
* D10: "after deployment" in D1 (1) means the deployment of R3.3;
* D11: the public-holiday exclusion setting also applies to the absence divisor;
* D12: a partly unscheduled Payroll Period: no deduction for the unscheduled portion, a warning, finalization
  allowed, normal calculation for the reliably scheduled dates;
* D13: the D6 payout uses the D5 (b) daily rate;
* D14: the "year" in D8 (b) is the calendar year of the carry-over.

They close Q3 and Q46 (a)–(e). D12 differs from the revision 8 recommendation for Q46 (c) (§18.7.2). The
consistency check found one new open point, Q47: how the D5 (b) rate applies when only part of a Payroll Period
has a reliable schedule or employment. R7.0 and G1 remain separate approval gates. Nothing in this plan is
implemented.

**Revision 10 (2026-11-06) — Q47 approved:** records the owner's approval of Q47 as **D15** (§2 O, §18.8). The daily
rate uses the same eligible dates in its numerator (salary actually attributable to those dates) and its denominator
(reliable scheduled working days among them). This applies to partial schedules, joiners, leavers, absence,
unpaid leave and the termination payout, and never puts a full monthly salary against a partial-period
denominator. For a fully eligible Payroll Period the rate is the D5 (b) / L28 rate, unchanged. The consistency check
found three open technical issues (OT1–OT3) and one new owner question, Q48 (unpaid leave for employees who have no
schedule). R7.0 and G1 remain separate approval gates. Nothing in this plan is implemented.

**Revision 11 (2026-11-06) — Q48 approved:** records the owner's approval of Q48 as **D16** (§2 P, §18.9).
Monthly-paid employees who have no work schedule, such as central employees, use **Calendar-day Proration** for
unpaid-leave deductions: no `ShiftAssignment` or schedule is required or invented for it, and nothing is divided by
zero scheduled working days. Employees with reliable schedules keep the scheduled-day calculation (D5 (b), L28,
D15). D16 changes no attendance, absence or classification rule. The exact Calendar-day Proration formula is not
decided: its open technical questions (OT4–OT8) go to R7's design review. The consistency check raised one new owner
question, Q49 (which employees D16 covers, and the payout for employees without a schedule). R7.0 and G1 remain
separate approval gates. Nothing in this plan is implemented.

**Revision 12 (2026-11-06) — Q49 approved:** records the owner's approval of Q49 (a) as **D17** and Q49 (b) as **D18**
(§2 Q, §18.10). D17: Calendar-day Proration (D16) applies only to monthly-paid employees whose classification is
explicitly "does not require attendance"; employees who require attendance never fall back to D16 when their
schedule is missing or unreliable, and the existing controls (warnings, C, D12, L32) stay. D18: for an employee who
does not require attendance and has no schedule when employment ends, the settlement of unused leave is **held for
HR/Payroll review**: never paid automatically, never forfeited or zeroed, balance and history preserved, recorded as
pending review. It holds the payout; it does not cancel the entitlement. The consistency check raised one new owner
question, Q50, and one open technical question, OT9. OT1–OT8 stay open. R7.0 and G1 remain separate approval gates.
Nothing in this plan is implemented.

**Revision 13 (2026-11-06) — Q50 approved:** records the owner's approval of Q50 (a) as **D19** and Q50 (b) as
**D20** (§2 R, §18.11). D19: the unused-leave settlement at termination stays configurable in each business's
Business Settings (`Pay Out` or `Forfeit`, the existing `paid` / `forfeited` setting); the setting is neither removed
nor changed globally. D18's hold takes priority while it lasts: a `Forfeit` setting never overrides it, and the held
balance is never forfeited, erased or zeroed while pending. Once the hold is released, the business's configured
policy applies, and `Forfeit` is never converted into `Pay Out`. D20: a held settlement is released only after (1) a
reliable payout calculation for employees who do not require attendance is formally approved, (2) HR reviews the
employment details and leave balance, (3) Payroll reviews and approves the settlement amount, and (4) the configured
policy is applied. Until then the balance stays preserved and pending, never paid automatically, never forfeited or
erased, and the full accrual, hold, review and settlement history is kept. No payout formula is decided: it remains
subject to formal owner approval. The consistency check raised one new owner question, Q51 (which version of the
setting applies at release), and narrowed OT9. OT1–OT8 stay open. R7.0 and G1 remain separate approval gates. Nothing
in this plan is implemented.

**Revision 14 (2026-11-06) — consolidation:** records the owner's approval of Q51 as **D21** (§2 S): a held
termination settlement applies the business's termination policy in force on the employment end date, captured as an
immutable snapshot (policy, effective date, business); later settings changes never alter it. Adds **§19, the
consolidated specification**, which governs the technical design wherever earlier sections differ: re-baseline
evidence on `origin/main` `3e01ac3` (§19.0); D1–D21 consolidated (§19.1); the question register (§19.2); OT2–OT9
resolved as technical decisions and OT1 raised as owner question **Q52**, with the same-person point of OT9 raised as
**Q53** (§19.3); approval-ready designs for **R7.0** (§19.4) and **G1** (§19.5), neither approved; the domain map,
rules, risks, traceability matrix, roadmap R0–R13 with a changed order (R10 and R11 before R7), readiness and the
remaining approval gates (§19.6–§19.12). No approved decision is reversed. Nothing in this plan is implemented.

**Revision 15 (2026-11-06):** records the owner's approval of Q52 as **D22** and of Q53 as **D23** (§2 T). D22: when
an employee who is required to attend has no scheduled working days in the final Payroll Period, the termination
settlement uses the last preceding reliable Payroll Period in which the employee had scheduled working days as the
reference period for the daily rate, and the settlement record preserves the reference period and the rate used;
Calendar-day Proration is never a fallback for employees who are required to attend, and no schedule is invented.
D23: the Super Admin controls permission assignment; the HR review (`manage_employees`) and the Payroll approval
(`finalize_payroll`) of a held settlement may be granted to the same person or to two people, and the system
enforces the permissions actually configured, with no mandatory two-person rule. The consistency check raised one
owner question, Q54, on details D22 does not settle. §19 is updated. No approved decision is reversed. Nothing in
this plan is implemented.

**Revision 16 (2026-11-06):** records the owner's answers to Q54 as **D24–D27** (§2 U). D24: D22 applies when the
employee has no reliably scheduled working day within the actual employment dates of the final Payroll Period;
scheduled days after the employment end date do not count. D25: without a preceding reliable Payroll Period with
scheduled working days, the termination leave settlement stays pending HR/Payroll review, never paid, forfeited,
zeroed or silently discarded. D26: the daily rate uses the salary in force on the employment end date, not the
reference period's salary. D27: a preceding Payroll Period is reliable if it contains at least one reliably
scheduled working day, and the rate uses only its reliably scheduled dates. The settlement record keeps the
reference period, the end-date salary, the dates used and the rate with its inputs. The consistency check raised
one non-blocking owner question, Q55 (how a D25 pending case is eventually resolved). §19 is updated. No approved
decision is reversed. Nothing in this plan is implemented.

**Revision 17 (2026-11-08):** the owner authorised the implementation of R3.1 and approved five R3.1 decisions,
recorded as **D28–D32** (§2 V). D28: when the durable pending audit record itself cannot be written, the
last-resort log may carry the full payload — only in that R3.1 fallback; the global `log_audit` / `log_audit!`
reporting is unchanged and BUG-003 is not resolved by it. D29: a delivered Audit Log entry carries the time of the
original attempt as its `created_at`. D30: the business dashboard shows operational information only, never the
payload. D31: R3.1 ships without a producer (the first is R3.4). D32: escalated unresolved events are shown on the
business dashboard and counted in a sidebar badge. The technical choices made while implementing R3.1 are in §19.13.
No approved decision is reversed.

**Revision 17 — R3.1 hardening (2026-11-08):** after an independent review of the R3.1 implementation the owner
authorised a hardening pass and decided **D33** (§2 V): a failure of the whole delivery transaction counts as a
failed attempt, recorded in an independent transaction. The same authorisation **clarified D28**: the full payload
may reach the last-resort *log* only, never an error reporter automatically (§2 V, note below the table). The
hardening choices are T-R31-11 … T-R31-15 (§19.13); T-R31-1, T-R31-7 and T-R31-8 are amended there, not rewritten.

**Revision 17 — R3.1 log retention (2026-11-10):** the owner approved the R3.1 log-retention policy as **D34**
(§2 V): bounded Docker log rotation (20 MB × 5 files, at most 100 MB per container, effective once the containers are
recreated), no automatic deletion of the full payload kept in the database, and never an automatic send of the full
payload to an external error reporter. This closes the open log-retention point of §5.

**Revision 18 (2026-11-11):** records that on 2026-11-10 the owner approved revision 17 of this plan as the primary
roadmap for the remaining phases. This closes the first approval gate of §19.12 and meets the prerequisite "owner
approval of this plan" of R1, R4 and R6 (§19.10). It authorises no phase: every phase still needs its own explicit
authorisation in the order of §19.10, and production work, migrations and deployments need separate approval. R1
was then authorised separately and merged (PR #121). Q55, the R7.0 design (A1–A6), the G1 design (G-A1–G-A6) and
D20 (1) stay open. No phase scope, dependency or owner decision is changed.

**Labels**

| Label | Meaning |
|---|---|
| **[C]** | Confirmed current behaviour, from the code at the baseline (read, not executed) |
| **[A]** | Owner-approved business rule (decision IDs A1–A12, B, C, D, E, F, G, H, I, J, K, L1–L35, the revision 8 owner decisions D1–D8 in §2 M, the revision 9 owner decisions D9–D14 in §2 N, the revision 10 owner decision D15 in §2 O, the revision 11 owner decision D16 in §2 P, the revision 12 owner decisions D17–D18 in §2 Q, the revision 13 owner decisions D19–D20 in §2 R, the revision 14 owner decision D21 in §2 S, the revision 15 owner decisions D22–D23 in §2 T, and the revision 16 owner decisions D24–D27 in §2 U, and the revision 17 owner decisions D28–D34 in §2 V) |
| **[P]** | Proposed implementation detail — consistent with the approved rules, still reviewable |
| **[Q]** | Unresolved question — needs an owner answer before the phase that depends on it |
| **[T]** | Technical decision recommended by the architecture review (§18): consistent with the approved rules and the module boundaries; no owner decision needed; engineering may still revise it in review |

**Relationship to other documents.** This plan **supersedes** the parts of
`docs/architecture/floating-employees-implementation-plan.md` listed in §4.3 (conflicts X1–X8); every other
decision of that plan stands. Architecture rules come from `docs/architecture/module-boundaries.md` and
`docs/architecture/migration-pattern.md`; they are referenced, not restated.

---

## 1. Executive summary

* **[C]** Today "must record attendance" is not modelled. Attendance, lateness and absence follow from having an
  active `ShiftAssignment`; the "Works shifts" checkbox (`users.requires_shift_assignment`) hides an employee in one
  of six assignment paths only. Absence is measured against one business-wide number (`working_days_per_month`,
  default 26) because no shift or assignment stores working weekdays. Employees without an assignment are charged to
  an arbitrary "first branch"; floating employees' costs go to an Unallocated line.
* **[A]** Approved direction: an effective-dated, Workforce-owned attendance requirement (`employee_attendance_requirements`
  as source of truth) enforced in every assignment path; absence from each assignment's own working weekdays, its
  active window, the payroll range and a Holiday Calendar; daily-paid and floating employees always require
  attendance; central employees (no attendance, no assignment) and floating employees are costed through
  Finance-owned, versioned **fixed-percentage Cost Allocation Rules**; salary and employer insurance share the rule
  version; Finance snapshots the result at payroll finalization through the extended `Payroll::FinalizationEffects`
  contract; missing data blocks finalization; history (including existing Unallocated records) is preserved and
  labelled, never redistributed.
* **[A]** Daily-paid attendance invariant (L1–L8): Attendance & Payroll owns the rule "every daily-paid employee
  requires attendance"; Workforce owns the requirement history, defines the check contract and the per-employee
  advisory lock; both change directions are validated over the whole effective-dated timeline and conflicting
  changes are rejected (never auto-resolved) and audited. Legacy assignments without weekdays warn but do not block
  finalization; a required employee with no assignment and schedule blocks it; new assignments need weekdays (L9).
* **[A]** Requirement history for everyone (L10–L13): HR explicitly selects the requirement when creating an
  employee (no implicit default); every existing employee is backfilled — daily-paid as required, everyone else as an
  explicit **Not Reviewed** row — from `hire_date` or the earliest reliable record, or placed on an HR exception list
  when no reliable date exists; a Not Reviewed employee cannot receive a daily salary profile.
* **[A]** Every new employee needs an HR-selected employment start date, from which the first requirement row starts
  (L18). The backfill uses `hire_date` only when it agrees with reliable records, otherwise the earliest reliable
  record; missing or conflicting evidence goes to the HR exception list (L19), where employees stay visible under
  legacy behaviour, with no invented dates and no new daily profile (L25).
* **[A]** Rejected invariant attempts are audited in a separate transaction after the rollback; a failed audit write
  is kept in a durable operational record, retried by a background job until it persists, and alerts system
  administrators if failures continue; the operation stays rejected (L14, L20). The alert channel is the WorkPulse
  administration notifications dashboard, showing failure status and retry information; email may follow later as a
  secondary channel. Neither the dashboard nor the integration with the existing `notifications` table exists yet
  (L29).
* **[A]** Workforce owns leave management; Attendance & Payroll consumes approved leave only (L15). Daily-paid: unpaid
  leave only (L6). Monthly-paid: paid annual leave (no salary reduction, reduces the leave balance) and unpaid leave
  (L16), with a business-level entitlement policy of service-duration tiers and a configurable accrual frequency
  (L22). Entitlement: 15 days/year in the first year, 21 from the second year, 30 after 10 full years, all
  configurable; a new tier's rate applies from the qualification date; balances kept to two decimals; carry-over
  of at most 5 days (configurable), the excess forfeited, carried days expiring on 31 March following the carry-over;
  termination settlement configurable (L26, L31). Approval is routed by the employee's position and configurable;
  cancelling approved leave needs approval at the original level; only approved leave affects attendance and payroll
  (L27). Unpaid leave is deducted as the applicable monthly salary ÷ scheduled working days in the **payroll
  period** × unpaid leave workdays, priced by the salary profile in force on each leave date, never a fixed divisor
  (L23, L28); when only part of the period is eligible, numerator and denominator cover the same eligible dates
  (D15). Leave approved — or cancelled — after a payroll lock never changes locked payroll; it goes to HR/Payroll
  review (L21, L27).
* **[A]** A historical conflict is recorded as a **Historical Violation**, shown on an HR/Payroll review report, and
  never changes locked payroll automatically; HR reviews the facts, Payroll the financial impact; corrections need
  permission and documented approval; a violation is never deleted, only closed with an audited reason (L17, L24).
  HR reviews with `manage_employees`, Payroll with `view_payroll`; executing a correction
  (`manage_historical_payroll_corrections`) and approving it (`approve_historical_payroll_corrections`) are separate
  permissions (L30).
* **[A]** Leave entitlement (L31): each employee has an individual leave year from the anniversary of the
  HR-approved Employment Start Date; entitlement is prorated by eligible service when employment starts or ends
  mid-year; a tier change inside a leave year splits accrual at the qualification date without recalculating
  earlier accruals; no negative balance — paid leave beyond the available balance is refused (unpaid leave may be
  requested instead); each carry-over batch (at most 5 days) is kept separately and expires on 31 March following
  that carry-over; consumption is FEFO; accrual continues during unpaid leave; the service date changes only by an
  authorised, reasoned, audited HR correction.
* **[A]** An unpaid-leave deduction that cannot be calculated reliably flags the employee **Flagged for Review** and
  blocks finalization for that employee only; the other employees continue (L32). Finalization is per period today,
  so the per-employee mechanism is a design dependency (Q40). D7 approves the business principle; the design
  needs its own approval (R7.0).
* **[A]** Leave types are configurable per business, each with explicitly defined balance, attendance and payroll
  effects, and inactive until those are defined and approved; a valid fallback approver must exist and nothing is
  approved automatically; self-approval is prohibited; a cancellation request does not itself cancel leave, and
  leave that already affected locked payroll is not cancelled but sent to HR/Payroll Review (L33).
* **[A]** Audit failures (L34): System Administrator monitors system-wide, a designated Business-level responsible
  person monitors their own business; escalation after 3 consecutive failed attempts; one notification per failed
  event, updated in place, marked Resolved (never deleted) on success; a System-Administrator-only **Retry Now** with
  no concurrent retries; business users never see another business's notifications — enforced in data and queries,
  not by UI filtering.
* **[A]** Historical payroll corrections (L35): independent `manage_historical_payroll_corrections` (HR, prepare /
  execute) and `approve_historical_payroll_corrections` (Finance Approvers) permissions at business level; executor ≠
  approver unless the business opts in; multiple Finance Approvers, any one approves, never twice; Super Admin
  approves only when the business has no Finance Approver; requests never expire, rejection needs a reason, a
  rejected request is kept and causes no financial effect, and a resubmission is a new linked request.
* **Open items:** Q1, Q2 and Q15–Q38 are resolved (L1–L35), Q34 except the termination payout amount (now Q39).
  Unresolved: Q3–Q14 (Q3 includes the transition deadline) and Q39–Q45 (§5): the termination payout amount; the
  per-employee finalization mechanism; the resubmission limit; the System Administrator and Super Admin identities;
  default role mapping; daily-paid employees and paid leave types; and minor leave operations. Each has a
  conservative recommendation marked **[P]**. None blocks the documentation phase. *(Status after revisions 8
  and 9: see the last two bullets of this section.)*
* **Revision 7 review (§18; its blocked list is superseded by revision 8):**
  * Technical questions (Q5–Q8, Q13, Q14 and the technical parts of Q4, Q10, Q40, Q42, Q43, Q45) are decided as
    **[T]** recommendations.
  * Eight grouped business decisions remain for the owner (§18.5).
  * Ready to build: R0, R1, R2, R8, plus the technical sub-phases of R3 and R4 (re-baseline first).
  * Blocked: R3's backdating rule (Q9), R3's system-wide dashboard (D1), R5's not-reviewed cut-off (Q3), R6b (Q44
    is non-blocking), R7 (Q10, Q11, Q40) and everything after it.
  * Key gaps:
    * no platform-operator identity exists;
    * per-period finalization against L32's per-employee block, together with the one-insurance-expense-per-period
      unique index;
    * a non-atomic job enqueue;
    * owners hold both correction permissions implicitly.
* **Revision 8 (§2 M, §18.6):** the owner approved D1–D8. *(Its open items are updated by revision 9, next
  bullet.)*
  * **Closed:**
    * Q3's HR review deadline;
    * the business parts of Q4 and Q40 (for Q40, the principle only);
    * Q9, Q10, Q11, Q12, Q39, Q41, Q42 (a)/(b), Q44 and Q45 (d).
  * **Still open:**
    * Q3's legacy-schedule end date;
    * the interpretation points Q46 (a)–(e);
    * approval of the R7.0 finalization-hold design (D7 is not implementation approval);
    * approval of the G1 platform-operator design.
  * **Readiness:**
    * ready now: R0, R1, R2, R3.1, R3.2, R4, R6, R8, and R7.0 as a design task;
    * ready after the phases they depend on: R3.4, R3.5, R3b, R5, R6b and R9;
    * still blocked: R3.3 (waits for R0), and R7 onwards (waits for the approved R7.0 design).
  * D5 (b) changes the absence deduction for every monthly-paid employee, so a Parity Report must be reviewed
    before rollout.
* **Revision 9 (§2 N, §18.7):** the owner approved D9–D14. *(Q47 was approved in revision 10, next bullet.)*
  * **Closed:** Q3 (the legacy-schedule end, D9) and Q46 (a)–(e) (D10–D14). No question from Q3 to Q46 is still
    open.
  * **Two separate deadlines:**
    * Not Reviewed employees: the end of the second complete Payroll Period after R3.3 is deployed (D1 (1), D10);
    * legacy assignments without working days: the end of the second complete Payroll Period after R4 is
      deployed (D9).
  * **Still open:**
    * Q47, found by the revision 9 consistency check: applying the D5 (b) rate when only part of a Payroll Period
      has a reliable schedule or employment (blocks R7 for those cases only);
    * approval of the R7.0 design;
    * approval of the G1 design.
  * **Readiness:** unchanged, except that R5 and R6b no longer wait for a confirmation, and R7 waits for Q47
    instead of Q46 (b)–(d).
* **Revision 10 (§2 O, §18.8):** the owner approved Q47 as D15. *(Q48 was approved in revision 11, next bullet.)*
  * **Rule:** the daily rate = salary actually attributable to the eligible dates ÷ reliable scheduled working
    days among the same dates, split at salary-profile changes. It applies to absence, unpaid leave and the
    termination payout, and to partial schedules, joiners and leavers.
  * **Unchanged:** a fully eligible Payroll Period gives exactly the D5 (b) / L28 rate.
  * **Still open:**
    * Q48 (owner): unpaid leave for monthly-paid employees without a schedule, such as central employees, who
      have no scheduled working days at all;
    * OT1–OT3 (technical, settled in R7's design review);
    * approval of the R7.0 design;
    * approval of the G1 design.
  * **Readiness:** R7 no longer waits for Q47. It still waits for R4, R5, R6, R6b, the approved R7.0 design and the
    Q5 column; Q48 blocks only unpaid leave for employees without a schedule.
* **Revision 11 (§2 P, §18.9):** the owner approved Q48 as D16. *(Q49 was approved in revision 12, next bullet.)*
  * **Rule:** monthly-paid employees without a work schedule, such as central employees, have unpaid leave
    deducted by **Calendar-day Proration**. No schedule is required or invented, and nothing is divided by zero
    scheduled days.
  * **Unchanged:** employees with reliable schedules keep the scheduled-day calculation (D5 (b), L28, D15); no
    attendance, absence or classification rule changes.
  * **Still open:**
    * OT4–OT8 (technical, R7 design review): the calendar-day denominator, salary changes, partial employment,
      rounding, and which leave days are counted. A formula that creates a business rule or changes a full-period
      result returns to the owner;
    * Q49 (owner): whether D16 also covers required employees whose schedule is missing or unreliable, and how
      the termination payout is priced for employees without a schedule;
    * OT1–OT3, approval of the R7.0 design, approval of the G1 design.
  * **Readiness:** R7 no longer waits for Q48. Unpaid leave for employees without a schedule waits for OT4–OT8 in
    the R7 design review.
* **Revision 12 (§2 Q, §18.10):** the owner approved Q49 (a) as D17 and Q49 (b) as D18.
  * **Two groups stay distinct:**
    * employees who do not require attendance by design (requirement in force = not required, such as central
      employees): unpaid leave by Calendar-day Proration (D16, D17);
    * employees who require attendance but have a missing or unreliable schedule: never D16; C, D12, L32 and the
      payroll-review warnings apply unchanged.
  * **Termination without a schedule (D18):** the leave settlement is held for HR/Payroll review, pending, with the
    balance and history preserved; never paid automatically, never forfeited or zeroed.
  * **Still open:**
    * Q50 (owner): (a) whether D18's hold also applies when the business's settlement setting is "forfeited";
      (b) the eventual payout calculation for these employees (non-blocking: the hold is implementable)
      *(decided in revision 13 as D19 and D20)*;
    * OT9 (technical): the review-and-resolution path for a held settlement;
    * OT1–OT8, approval of the R7.0 design, approval of the G1 design.
  * **Readiness:** R7 no longer waits for Q49. It still waits for R4, R5, R6, R6b, the approved R7.0 design and the
    Q5 column, with OT1–OT9 settled in its design review.
* **Revision 13 (§2 R, §18.11):** the owner approved Q50 (a) as D19 and Q50 (b) as D20.
  * **The business setting stays the normal policy (D19):** each business configures `Pay Out` or `Forfeit` in
    Business Settings; nothing removes it or changes it globally, and every leaver outside D18 is settled by it as
    before (D6, L26, L31).
  * **D18 is a specific, temporary hold:** while a settlement is held, `Forfeit` does not override it, and the
    balance is never forfeited, erased or zeroed. A held balance is an existing entitlement whose payout decision is
    pending.
  * **Release (D20):** only after a formally approved payout calculation for employees who do not require attendance,
    HR's review of the employment details and balance, and Payroll's approval of the amount; then the business's
    configured setting is applied. `Forfeit` applied after release is a reviewed, recorded forfeiture entry, not a
    silent one; `Forfeit` is never converted into `Pay Out`.
  * **Still open:**
    * Q51 (owner): which version of the setting applies when the business changes it while a settlement is held, the
      one in force on the employment end date or on the release date (non-blocking: nothing is released before D20
      (1)) *(decided in revision 14 as D21)*;
    * the payout calculation itself (D20 (1)): a future formal owner approval, not designed in this plan;
    * OT9 (technical, narrowed): the permissions for the HR and Payroll steps, whether one person may perform both,
      rejected reviews, and how a payout released after the final period is locked is paid;
    * OT1–OT8, approval of the R7.0 design, approval of the G1 design.
  * **Readiness:** unchanged for R6b and R7, which build the hold and its review steps; releasing a held settlement
    also waits for D20 (1).
* **Revision 14 (§2 S, §19):** the owner approved Q51 as D21; the plan is consolidated in §19.
  * **D21:** a held settlement keeps the termination policy in force on the employment end date, as an immutable
    snapshot; a later settings change never alters it; on release the snapshot is applied, and `Forfeit` is never
    converted into `Pay Out`.
  * **Technical questions:** OT2–OT9 resolved in §19.3 (scheduled-day and calendar-day rates, salary splits, mixed
    periods, rounding, leave-day counting, held-settlement steps). OT1 needs a pricing rule and is owner question
    Q52; whether one person may do both D20 reviews is owner question Q53. Both have a never-silent interim.
    *(Decided in revision 15 as D22 and D23.)*
  * **Designs:** R7.0 (§19.4) and G1 (§19.5) are approval-ready, with listed approval items; neither is approved.
  * **Roadmap:** R10 (contract extension and hold infrastructure) and R11 (Provisional reporting) now come before R7
    (§19.10).
* **Revision 15 (§2 T, §19):** the owner approved Q52 as D22 and Q53 as D23.
  * **D22:** a leaver who is required to attend and has no scheduled working day in the final Payroll Period is
    paid out at a daily rate taken from a reference period, the last preceding reliable Payroll Period in which
    the employee had scheduled working days; the reference period and the rate are recorded. Never Calendar-day
    Proration for required employees (D17 unchanged); no schedule invented.
  * **D23:** the HR review and the Payroll approval of a held settlement follow the permissions the Super Admin
    configures (`manage_employees`, `finalize_payroll`); one person may hold both. No two-person rule, no new
    permission.
  * **Still open:** Q54 (owner): what happens when no reference period exists, which salary profile prices the
    reference rate, and what makes a period "reliable" (§19.2). A never-silent interim applies.
    *(Decided in revision 16 as D24–D27.)*
  * **Readiness:** R7's D22 payout code waits for Q54 (b) and (c); the rest of R7 is unchanged. Release of held
    settlements still waits for D20 (1).
* **Revision 16 (§2 U, §19):** the owner answered Q54 with D24–D27.
  * **D24 (scope):** only the actual employment dates of the final Payroll Period count; scheduled days after the
    employment end date do not.
  * **D25 (no reference period):** the settlement stays pending HR/Payroll review; never paid, forfeited, zeroed
    or silently discarded.
  * **D26 (salary):** the salary in force on the employment end date, not the reference period's salary.
  * **D27 (reliable period):** at least one reliably scheduled working day; the rate uses only the reliably
    scheduled dates; unscheduled dates are never treated as working days.
  * **Record:** reference period, end-date salary, reliably scheduled dates used, daily rate and its inputs.
  * **Still open:** Q55 (owner, non-blocking): how a D25 pending case is eventually resolved (§19.2).
  * **Readiness:** R7's D22 payout code no longer waits for an owner decision; a D25 case is built as pending.

---

## 2. Complete approved business rules **[A]**

### A — Attendance and shifts

| ID | Rule |
|---|---|
| **A1** | Replace `requires_shift_assignment` with `requires_attendance` gradually. Three separate concepts: (1) must the employee record attendance; (2) does the employee have a `ShiftAssignment` on a date; (3) how attendance, lateness, absence and deductions are calculated. |
| **A2** | Employees not yet reviewed by HR keep legacy behaviour temporarily: they stay eligible for assignments under legacy rules, are never silently classified `requires_attendance = false`, appear on an HR "not reviewed" report, and a defined review deadline precedes mandatory enforcement. *(Exception-list employees: L25; deadline: D1 (1), §2 M.)* |
| **A3** | `employee_attendance_requirements` is the authoritative, effective-dated history. `users.requires_attendance` may remain temporarily as a cache, updated only by one Workforce-owned service in the same transaction as the history row; never independently editable. |
| **A4** | An employee explicitly not requiring attendance receives no `ShiftAssignment` through any path — individual UI, bulk, API, templates, temporary coverage, floating, editing an existing assignment — enforced server-side at the Workforce boundary. "Not reviewed" employees keep legacy eligibility during the transition. |
| **A5** | Changing required → not required: history kept and never reinterpreted; the change has an effective date; future assignments must be ended or cancelled before the change is accepted; audit of old/new value, effective date, actor and reason; HR with `manage_employees` changes it directly (no approval step); backdating allowed only when it touches no locked, finalized, approved or paid payroll period, and needs a reason. *(Refined by D4: backdating is refused once an affected payroll period is Under Review or later; before that, these controls apply.)* |
| **A6** | Absence uses the employee's scheduled working weekdays, the assignment's active date window and the payroll date range. `working_days_per_month` is never a substitute for the employee's schedule. |
| **A7** | Existing assignments without working weekdays: no absence deduction for undefined days, a clear payroll-review warning, never a silent fallback to 26 days. New assignments: a working schedule is mandatory. *(The legacy exception ends at the D9 deadline, §2 N.)* |
| **A8** | Rotating schedules use successive assignments (start, end, shift, working weekdays). No recurring-pattern engine in this phase. |
| **A9** | Every daily-paid employee requires attendance and records check-in/out; `requires_attendance = false` is impossible for them; they need an applicable assignment and schedule; pay from approved actual attendance under the payroll rules; no exception. |
| **A10** | Approved public and company holidays never count as absence. A Holiday Calendar represents both. *(First implementation: one business-wide calendar, D3.)* |
| **A11** | Floating employees require attendance; their attendance and absence use their own assignments and schedules, not a home branch. PR #110's cross-branch biometric attribution is preserved and PR #110 is not modified. |
| **A12** | Workforce owns the attendance-requirement classification and history, shift assignments and schedules; Attendance & Payroll owns attendance and payroll calculations; Finance & Sales owns allocation rules and results; Organization & Access owns permissions. No new Scheduling or Attendance domain. |

### B — Central employees

A central employee has `requires_attendance = false`, no home branch, no `ShiftAssignment`, records no attendance,
and must have a Finance Cost Allocation Rule (100 % to one branch or split). Never attributed to an arbitrary first
branch. Salary, employer insurance and related business costs use the allocation mechanism. *(Unpaid leave for
central employees: D16, Calendar-day Proration, limited to not-required employees by D17; leave payout at
termination: held for review, D18, released only under D20 (D19). It changes neither this classification nor the allocation rule;
the allocated salary is the salary after the deduction, as for any other employee.)*

### C — Required attendance without a shift

An employee who requires attendance but has no applicable assignment and working schedule during their active
employment period blocks payroll finalization; payroll review shows the employee and the exact missing period/data;
an allocation rule does not compensate; hire and termination dates are respected; no absence outside the
employee's actual assignment window.

### D — Expense allocation

Every business-level expense is fully allocated before financial approval: one branch directly, or equal /
percentage (exactly 100.00 %) / fixed amounts (exactly the expense amount at 2 dp). Only active and authorised
branches. 2-dp rounding with a deterministic remainder. Approved allocations are immutable snapshots. No new
Unallocated amounts in finalized reports. Branch-specific expenses stay direct. Recurring templates validate their
allocation when saved. Drafts/pending may be incomplete only where the existing lifecycle permits, never past approval.

### E — Employer insurance

Insurance uses the same allocation percentages and rule version as the employee's salary: compute the actual
insurance amount first, then distribute it with the salary percentages; keep the snapshots.

### F — Provisional reporting

Draft and Under Review payroll costs may appear in branch reports, clearly marked **Provisional**; finalized and paid
costs are distinguishable; provisional amounts are never mixed into finalized totals without explicit labelling.

### G — Permission

A separate permission, provisionally `manage_cost_allocations`: business-level, respecting the user's authorised
branch scope, separate from `manage_employees`, manages rules and future versions, never edits finalized snapshots.

### H — Historical Unallocated data

Existing Unallocated and Unattributed records are preserved as they are and labelled historical; never automatically
redistributed; new rules apply to new periods; any historical correction needs a separate approved decision and
audited compensating entries.

### I — Central-staff privacy

Ordinary branch reports show central employee costs only as the aggregate category **"Allocated Central Staff
Costs"** — no names, no individual salary amounts. Individual details stay behind existing payroll-cost access.
*(Label refined by D2: **"Allocated Central & Floating Staff Costs"**, one aggregate line that also contains the
floating employees' allocated costs. The privacy rule is unchanged.)*

### J — Floating employee cost allocation (first implementation)

Fixed-percentage Cost Allocation Rules. Every floating employee needs a valid rule totalling exactly 100 %; salary
and insurance share its percentages; the applied rule version is snapshotted per finalized period; biometric branch
activity is **not** an allocation driver in this phase (may be revisited after BUG-044 and related device-branch
auditing issues are addressed).

### K — Payroll → Finance architecture

Extend the existing `Payroll::FinalizationEffects` contract. Payroll calculates salary and insurance and supplies
per-employee cost details through the contract; Finance validates allocation readiness, creates snapshots and fully
allocated expense records; missing allocation blocks finalization. Payroll keeps the calculations and the
finalization lifecycle; Finance keeps allocation rules, calculations and results. No upward dependency; no payroll
logic in Finance.

### L — Daily-paid attendance invariant, requirement history, leave and legacy schedules (approved 2026-11-05)

L1–L9 were approved in revision 2, L10–L17 in revision 3, L18–L25 in revision 4, L26–L30 in revision 5, L31–L35 in
revision 6. Where a later decision refines an earlier one, the later one is noted in the earlier row.

| ID | Rule |
|---|---|
| **L1** | **Ownership (former Q2).** Attendance & Payroll owns the business invariant "every daily-paid employee requires attendance" (A9). Workforce owns the attendance-requirement history and **defines** the read/validation contract; AP **implements** it. AP may read Workforce's requirement history (the allowed AP → WF direction). Workforce never references AP concepts and never depends on Payroll. No circular dependency. |
| **L2** | **Both directions, whole timeline, reject only.** (1) A daily salary profile cannot be created or changed while the employee is not required to attend on any date it would be in force. (2) An attendance requirement cannot change to not required if that conflicts with any daily-paid date. Both sides validate the complete effective-dated timeline, future-dated salary profiles and requirement rows included. The existing admin correction of `salary_type` and `effective_from` on a salary profile stays, and must pass the same validation. A conflict is never resolved automatically (no change to salary type or requirement): the operation is rejected with the reason. |
| **L3** | **Concurrency.** One per-employee PostgreSQL advisory transaction lock, owned by Workforce. Both AP and WF acquire it for the employee before validating or changing either side of the invariant, inside the transaction, held until commit or rollback, with the same lock order in both services. It stops two simultaneous changes from each passing validation alone. Payroll recalculation stays after commit, as today, unless a later approved design changes it. Not a `users` row lock. |
| **L4** | **History and backfill.** Every new employee receives an `employee_attendance_requirements` row at creation, effective from the employee's employment start date. Existing employees are backfilled; every daily-paid employee is backfilled as required. An existing employee without a history row never silently becomes not required: they stay Not Reviewed (A2) until HR reviews them. *(Refined by L10 — explicit HR selection at creation; L11 — every existing employee gets a row, Not Reviewed being an explicit value; L12 — effective-date precedence.)* The effective-dated history is the source of truth; `users.requires_attendance`, if kept as a cache, is written only by the Workforce service in the same transaction as the history change, is never independently editable, and is never the source for invariant checks. `requires_attendance` is never added to `UserPolicy::EMPLOYMENT_ATTRIBUTES`. |
| **L5** | **History-wide validation, locked payroll untouched.** The invariant applies across the complete effective-dated history. A historical conflict inside a locked, finalized or paid payroll period never automatically reopens, recalculates or modifies that period; it is handled by a separate, audited corrective process *(detailed by L17 — Historical Violations)*. The invariant asks whether the employee was **required to attend** on each daily-paid date — not whether a punch exists on every calendar day; approved leave, scheduled rest days and approved holidays are handled by the attendance and payroll rules. |
| **L6** | **Daily-paid leave.** Daily-paid employees receive unpaid leave only. An approved unpaid leave day is not an absence, does not count as a paid workday for daily payroll, and receives no additional absence deduction. Daily-paid employees remain subject to attendance requirements on their scheduled working days; taking leave changes neither `requires_attendance` nor `salary_type`. Attendance classification, leave approval and paid/unpaid entitlement, and payroll treatment stay three separate concepts. *(Monthly-paid leave: L16. Leave ownership: L15. Configurable leave types do not change this rule: L33; confirmed by D8 (a).)* |
| **L7** | **Daily → Monthly conversion.** A separate salary operation: a new effective-dated monthly salary profile; historical daily profiles are preserved. Conversion does not set `requires_attendance = false`; the requirement is unchanged until HR makes a separate, valid, effective-dated change — which is still rejected if it conflicts with any daily-paid date. No automatic conversion workflow. |
| **L8** | **Rejected attempts are audited.** Every rejected attempt to violate the invariant is recorded in the Audit Log with, where applicable: target employee, attempted operation, current and requested values, conflict/rejection reason, actor, date and time. A rejected operation leaves no invalid salary profile or requirement history row. The mechanism is to be verified during implementation (§6.6, §11); the existing audit infrastructure is not assumed to support it. *(Transaction placement and failure handling: L14.)* |
| **L9** | **Legacy schedules (former Q1).** (1) An existing (legacy) assignment without `working_weekdays`: payroll-review warning, no absence deduction for undefined weekdays, finalization allowed temporarily under this legacy exception. (2) An employee who requires attendance with no applicable assignment and working schedule during the active employment period blocks finalization (C). (3) A new assignment without `working_weekdays` is rejected. The legacy exception never extends to new assignments. *(End of the exception: D9, the end of the second complete Payroll Period after R4 is deployed; after it, dates on an assignment without working days have no working schedule and fall under (2), §18.7.2 K16. Partly scheduled periods: D12.)* |
| **L10** | **New employees (former Q15).** HR must explicitly select the attendance requirement when creating an employee; the selection is mandatory and there is no hidden or implicit default. The initial `employee_attendance_requirements` row is effective from the employee's employment start date. Required (`requires_attendance = true`): the employee must attend and is eligible for applicable `ShiftAssignment`s. Not required (`false`): not required to attend and cannot receive `ShiftAssignment`s (A4). Daily-paid employees always have `requires_attendance = true`; incompatible employee or salary creation operations are rejected (L2). *(Start date: L18.)* |
| **L11** | **Backfill every existing employee (former Q16-A).** Every existing employee — monthly and daily — receives an attendance requirement history record. Employees not yet reviewed by HR are recorded explicitly as **Not Reviewed**. Monthly pay never implies "not required". Every daily-paid employee is backfilled as required, subject to reliable date handling (L12). |
| **L12** | **Backfill effective date (former Q16-B).** Precedence: (1) `hire_date` when present and valid; (2) otherwise the earliest reliable employment or salary record date; (3) if no reliable date exists, no date is invented: the employee goes on an **HR exception list** and HR review is required before that employee's backfill is completed. *(Evidence rule refined by L19; exception-list behaviour L25.)* |
| **L13** | **Not Reviewed and daily profiles (former Q16-C).** A new daily salary profile is not allowed for an employee whose requirement is Not Reviewed; HR first reviews the employee and explicitly sets required. All other invariant checks still apply after review. |
| **L14** | **Rejected-attempt audit transaction (former Q17).** The conflicting operation is rejected and its main transaction rolled back; the rejected attempt is then recorded in a **separate transaction after the rollback**, with target employee, attempted operation, current and requested values, rejection reason, actor and timestamp where available. An audit-write failure is never silently swallowed: it raises an operational alert and goes through a retry / recovery mechanism. No invalid salary profile or requirement row is ever persisted. This is a **design requirement, not an existing capability**. *(Retry, durable record and alerting: L20.)* |
| **L15** | **Leave ownership (former Q18).** Workforce owns leave management: leave requests, leave types, the approval workflow, leave dates and status, and leave entitlement records as appropriate. Attendance & Payroll consumes **approved** leave data and applies its effect to attendance and payroll; leave has no attendance or payroll effect until approved. Finance & Sales owns no leave workflow or approval. No circular dependency. *(Approval routing and cancellation: L27.)* |
| **L16** | **Monthly-paid leave (former Q19).** Monthly-paid employees have a paid annual leave entitlement and may also take unpaid leave. Approved paid annual leave does not reduce salary; it reduces the employee's leave balance. Approved unpaid leave affects salary according to the payroll rules. Balance, accrual rate, carry-over, expiry and other entitlement details are **not decided** at L16 *(policy approved later as L22 and L26; still open: Q34)*. The daily-paid policy (L6: unpaid leave only) is unchanged. *(Entitlement policy: L22, L26; unpaid-leave deduction: L23, L28.)* |
| **L17** | **Historical Violations (former Q20).** A historical conflict between daily salary periods and the requirement history is recorded as a **Historical Violation**; locked, finalized or paid payroll is never automatically reopened, recalculated or modified; violations are visible on an HR/Payroll review report; any financial correction uses a separate audited process with appropriate authorisation and approval; historical amounts are never redistributed or altered automatically. *(Review roles and closing: L24; post-lock leave: L21.)* |
| **L18** | **Employment start date (former Q21).** The employment start date is mandatory for every new employee and is explicitly selected by HR; there is no hidden default. The initial attendance requirement history row starts on this date. *(It is also the service date for leave; correction process: L31.)* |
| **L19** | **Backfill evidence (former Q22).** A `hire_date` is used only when it is valid and does not conflict with reliable employment records; otherwise the earliest reliable employment or salary record date is used. If the evidence is missing or conflicting, the employee goes to the HR exception list; a date is never invented. |
| **L20** | **Durable rejected-attempt audit (former Q23).** Rejected invariant attempts are audited after the original transaction rolls back. If the Audit Log write fails, a background job retries it; the event is preserved in a **durable operational record** until Audit Log persistence succeeds; system administrators are alerted if failures continue. The invalid operation remains rejected. *(Alert channel: L29.)* |
| **L21** | **Leave approved after a payroll lock (former Q24).** Leave approved after the affected payroll period is locked keeps its actual leave dates and approval timestamp. Locked payroll is never reopened or modified automatically; the leave is flagged for HR/Payroll review; any financial correction is a separate audited process. *(Cancellation of leave that affected locked payroll: L27.)* |
| **L22** | **Annual leave entitlement policy (former Q25).** Monthly-paid employees have paid annual leave and may take unpaid leave. The annual entitlement is configurable at business level through **service-duration tiers** and an **accrual frequency** (monthly, quarterly, semi-annually or annually). Initial example: first year 15 days/year; from the second year 21 days/year; after completing 10 full years 30 days/year. One unified policy per business initially, designed so branch- or employee-specific policies can be added later. Carry-over, expiry, proration and any other entitlement rule were **not approved** at L22. *(Refined by L26: tier values, tier transitions, precision, carry-over, expiry, termination settlement. Proration, negative balances and the other details remain open: Q34.)* |
| **L23** | **Monthly unpaid-leave deduction (former Q26).** `monthly_salary / scheduled_working_days_in_month × unpaid_leave_workdays`, from the employee's actual scheduled working days in that month; rest days are excluded. No fixed 30-day or hard-coded 26-day divisor. If the schedule or the denominator is missing or invalid, the case is flagged for review; no denominator is invented. *(Refined by L28: payroll period instead of calendar month, salary profile per leave date, configurable public-holiday exclusion. Whether a flagged case blocks finalization: Q35.)* |
| **L24** | **Historical Violation review (former Q27).** HR reviews the employee and attendance facts; Payroll reviews the financial impact. Financial corrections require appropriate permission and documented approval. A violation is never deleted: it is closed through an audited corrective action with a reason. *(Permissions: L30.)* |
| **L25** | **HR exception list (former Q28).** Employees on the HR exception list stay visible and under legacy behaviour temporarily. No employment date or attendance history is invented. No new daily salary profile until HR reviews the employee and explicitly sets `requires_attendance = true`. Existing attendance and payroll history is never reinterpreted. *(Transition deadline: decided by D1 (1), the end of the second complete Payroll Period after R3.3 is deployed (D10), §2 M, §2 N.)* |
| **L26** | **Annual leave balance rules (former Q29).** *Tiers:* first year 15 days/year; from the second year 21 days/year; after completing 10 full years 30 days/year. Tier values are configurable in business-level settings; the accrual frequency is configurable (monthly, quarterly, semi-annually or annually); one unified policy per business initially. *Tier transitions:* the new accrual rate applies from the date the employee qualifies for the new tier; balance already accrued is preserved; each accrual period is calculated at the rate in effect during that period. *Precision:* balances are stored and calculated to **two decimal places**; accruals are not rounded to whole days; display rounding never changes stored values. *Carry-over:* enabled; maximum initially **5 days**, configurable in business settings; any balance above the maximum is forfeited under the policy; carried-over days **expire on 31 March of the following year**. *Termination settlement:* whether unused balance is paid out on termination is configurable in business settings; balance and settlement history are preserved; neither payment nor forfeiture is assumed. No other entitlement rule (proration, negative balances, other carry-over exceptions) is approved (Q34). *(Refined by L31: anniversary leave year, proration, tier split, no negative balance, carry-over batches, FEFO, service date, accrual during unpaid leave. The expiry is now "31 March following the relevant carry-over" (L31), which equals "31 March of the following year" only for a calendar leave year; L31 governs. The 5-day maximum stays configurable as approved here. Payout amount: decided by D6, D13 and D15; held for review without a schedule, D18. Setting labels `Pay Out` / `Forfeit` and D18's priority over `Forfeit`: D19; release of a held settlement: D20. Expiry wording settled by D8 (b) and D14, which matches "31 March of the following year" here.)* |
| **L27** | **Leave approval and cancellation (former Q30).** *Routing:* branch employee → branch manager; branch manager → area manager or HR; central employee → HR or a designated responsible approver; routing is configurable in business settings. Only **approved** leave affects attendance and payroll. *Cancellation:* an employee may request cancellation of approved leave; the cancellation needs approval at the same level as the original approval. If the leave already affected locked payroll, that payroll period is not modified: the case goes to HR/Payroll review and any financial correction goes through a separate audited process. *(Refined by L33: cancellation may be requested only while the leave has not affected locked payroll; a request after that leaves the leave and payroll history unchanged and becomes an HR/Payroll Review case. Fallback approver and self-approval ban: L33.)* |
| **L28** | **Monthly unpaid-leave deduction (former Q31).** `unpaid_leave_deduction = applicable_monthly_salary / scheduled_working_days_in_payroll_period × unpaid_leave_workdays`, from the employee's actual scheduled working days in the **payroll period** (not necessarily the calendar month); weekly rest days excluded; no fixed 30-day or 26-day divisor. Whether approved public holidays are excluded from the denominator is configurable in business settings. When the salary changes during the period, each unpaid-leave date uses the salary profile in force on that date, and the calculation is split at salary-profile effective-date boundaries. Missing or invalid schedule or denominator data is flagged for review; no denominator is invented. Whether a flagged case blocks finalization is **not decided** (Q35); the existing finalization rules (C, L9) are unchanged. *(Decided by L32: blocks finalization for the affected employee only. The holiday setting also governs the D5 (b) absence denominator: D11. Partly scheduled or partly employed periods: D12, D15. Employees without a work schedule: D16, Calendar-day Proration instead of this formula.)* |
| **L29** | **Audit-failure alerts (former Q32).** The primary channel is the WorkPulse **administration notifications dashboard**. System administrators are notified when audit persistence fails repeatedly, with failure status and retry information. Automatic retries continue through the approved background job (L20); the durable operational record stays the source for pending audit recovery. Email may be added later as a secondary channel. The existing `notifications` table is **not** integrated today; the integration is still to be built. *(Refined by L34: ownership, escalation threshold, dashboards and tenant isolation, de-duplication, resolution, manual retry.)* |
| **L30** | **Historical Violation permissions (former Q33).** HR employee and attendance review: `manage_employees`. Payroll financial-impact review: the existing permission to view payroll data (`view_payroll`). Executing a financial correction: `manage_historical_payroll_corrections` (new). Approving a financial correction: `approve_historical_payroll_corrections` (new). Execution and approval are separate permissions to enforce separation of duties. Historical Violations are never deleted; corrections are audited, authorised and approved. *(Workflow, approvers and role defaults: L35.)* |
| **L31** | **Leave entitlement policy (former Q34).** *Leave year:* individual per employee, from the anniversary of the HR-approved Employment Start Date, not the calendar year. *Proration:* entitlement prorated by the actual eligible service period when employment starts or ends partway through a leave year. *Tiers:* first year 15 days/year; from the second year 21; after completing 10 full years 30. A higher tier reached during a leave year splits accrual at the effective qualification date: the earlier part at the old rate, the later part at the new rate; previously accrued balances are never recalculated. *Negative balances:* not allowed; paid annual leave is not approved when the available balance is insufficient; the employee may request unpaid leave instead. *Carry-over and expiry:* allowed, at most 5 days; carried-over days expire on 31 March following the relevant carry-over; each carry-over batch is kept separately with its source, amount and expiry date. *Consumption:* FEFO (first expiring, first out) — the carried-over balance closest to expiry is used before the current entitlement; every consumption keeps its source and expiry information. *Service date:* the HR-approved Employment Start Date is the reference for service length and tiers; HR may correct it through an authorised process requiring a reason and an audit record with old value, new value, actor and timestamp; branch or job changes never change it automatically. *Unpaid leave:* accrual continues during unpaid leave. *Termination payout:* whether unused annual leave is paid at termination is a configurable business-level policy; balance and settlement history are preserved. *(Payout amount and payroll treatment: decided by D6, rate D13 over the eligible dates of D15; held for review for an employee without attendance requirement and schedule, D18; the business setting applies only after release, D19, D20. Carry-over expiry clarified by D8 (b) and D14.)* |
| **L32** | **Unpaid-leave calculation exceptions (former Q35).** When an unpaid-leave deduction cannot be calculated reliably because schedule data or the denominator is missing or invalid, the affected employee is **Flagged for Review** and payroll finalization is blocked **for that employee only**; other employees may continue through finalization. A denominator is never invented, no fixed 26 or 30 is substituted, and no unreliable deduction is calculated silently. *(Mechanism — finalization is per period today: Q40. D7 approves the business principle; the technical design needs separate approval in R7.0. A monthly-paid employee without a work schedule is no longer flagged merely for having no schedule: D16. D17: D16 never covers required employees with a missing or unreliable schedule; for them this rule applies unchanged.)* |
| **L33** | **Leave types, approvals and cancellations (former Q36).** *Leave types:* configurable per business (e.g. sick, marriage, bereavement, annual paid, unpaid); each type explicitly defines its effect on the leave balance, on attendance and absence classification, and on payroll; a new type is not activated until those effects are defined and approved. *Routing:* ordinary branch employee → Branch Manager; Branch Manager → Area Manager or HR, per business settings; central employee → HR or a business-designated approver. A valid fallback approver must exist; no request is approved automatically when no valid approver is available. *Self-approval:* strictly prohibited, even when the requester holds approval permissions; the request goes to a fallback approver or a higher level; `Approvals::SelfApproval` is reused where appropriate. *Cancellation:* an employee may request cancellation of approved leave that has not already affected locked payroll; it needs approval at the same level as the original approval; submitting the request does not cancel the leave; request and approval are audited. If cancellation is requested after the leave affected locked payroll: the old payroll is not modified or reopened, the original leave and payroll history stay unchanged, the case is flagged for **HR/Payroll Review**, and any financial correction uses a separate audited correction process. |
| **L34** | **Audit-failure recovery and notifications (former Q37).** *Ownership:* the System Administrator is responsible for system-wide technical audit-failure monitoring; a designated Business-level responsible person may monitor issues belonging to that business; responsibility is explicit. *Repeated failures:* escalation after **3 consecutive failed attempts** for the same audit event; automatic retries continue until success; pending audit events are never discarded or silently ignored. *Dashboards:* a system-wide dashboard for the System Administrator and a Business-level dashboard limited to that business's own notifications; business users never access another business's notifications or data; tenant isolation is designed into the data and queries — UI filtering alone is not sufficient (the existing `notifications` table has no `business_id`). *De-duplication:* one notification per failed audit event, updated with retry count, last error and last attempt time; no duplicates for repeated failures of the same event. *Resolution:* when the event is recorded, its notification is marked **Resolved**; resolved notifications are never deleted; failure history, retries and resolution are retained. *Manual retry:* a **Retry Now** action, available only to the System Administrator in the first implementation; business-level responsible users view and monitor their own notifications but cannot retry; each manual retry records the administrator, timestamp and result; concurrent retries of the same event are prevented; automatic retries stay enabled. |
| **L35** | **Historical payroll correction permissions and workflow (former Q38).** *Permissions:* `manage_historical_payroll_corrections` (prepare / execute) and `approve_historical_payroll_corrections` (approve) are independent, separate from ordinary payroll permissions; neither implies the other; no ordinary payroll permission grants either. *Separation of duties:* by default executor and approver are different people; a business may explicitly opt in to an exception allowing one person holding both to execute and approve the same correction; audit always records executor and approver separately. *Default roles:* HR → `manage_historical_payroll_corrections`; Finance Manager or a designated financial approver → `approve_historical_payroll_corrections`; never granted automatically to unrelated roles. *Scope:* both business-level — across the business's branches, never another business's data; existing financial data access restrictions still apply. *Finance Approvers:* a business may designate several; any one may approve; the actual approver and timestamp are recorded; a correction is never approved more than once, including under concurrent requests (transactional / concurrency protection). *Super Admin fallback:* Super Admin may approve only when the business has no designated Finance Approver, never bypassing or overriding one; the correction stays **Pending Approval** until an actual authorised approval; the Super Admin's identity and fallback reason are recorded; business scope and tenant isolation are preserved. *Managing Finance Approvers:* HR has a separate permission to add or remove Finance Approvers in their own business only; Super Admin keeps administrative intervention; every addition, removal and change is audited. Removing an approver never deletes or cancels pending corrections: they stay Pending Approval and pass to a remaining Finance Approver, or to Super Admin when none remains; HR may remove the last Finance Approver even with corrections pending; earlier approvals and audit records are never rewritten. *Pending and rejection:* requests never expire; they stay Pending Approval until approved or rejected; rejection needs a mandatory reason and records the rejecter, timestamp and reason; rejected requests are kept permanently and cause no financial execution. *Resubmission:* HR may submit a new request after a rejection — an independent record with updated justification and data, linked to the rejected one, which stays unchanged; the new request goes through the full approval workflow. *(Resubmission limit: none, D8 (c). Super Admin = the business owner: D1. HR and Finance Manager presets: Q43 **[T]**.)* |

### M — Revision 8 owner decisions D1–D8 (approved 2026-11-05)

These IDs are separate from the module-boundaries owner decisions D1–D4 (§20.3) and from rule D above. They were
requested in §18.5 and are now **[A]**. Where a decision refines an earlier rule, that rule's row carries a note.

| ID | Rule |
|---|---|
| **D1** | **Transition deadline and platform roles (former Q3 in part, Q42 (a)/(b)).** (1) The HR review deadline for employees marked Not Reviewed is the end of the **second complete Payroll Period after deployment**. Q3 defined it as the transition deadline for Not Reviewed employees and for HR-exception-list employees, who are treated as Not Reviewed (§6.2, L25). (2) **System Administrator** means the WorkPulse platform operations team. (3) **Super Admin** means the business owner. (4) Platform-operator responsibilities stay separate from business-owner permissions: no business role, permission or ownership grants platform access, and platform access grants no business permission. *(The end of the L9 (1) legacy-schedule exception, the other half of Q3, is set by D9. "After deployment" means after the deployment of R3.3: D10.)* |
| **D2** | **Central and floating cost label (former Q12).** Exact report label: **"Allocated Central & Floating Staff Costs"**. It is one aggregate cost line. Ordinary branch reports never show individual employee names or individual salaries; individual details stay behind the existing payroll-cost access (I). |
| **D3** | **Holiday calendar scope (former Q4, business part).** In the first implementation, public and company holidays use **one business-wide calendar**. No branch-specific holiday calendars in this phase. |
| **D4** | **Backdated attendance-requirement changes (former Q9).** A backdated change to the attendance requirement is prohibited once any affected Payroll Period has reached **Under Review** or a later state: `under_review`, `branch_review_completed`, `finalized` or `paid`, which covers approval, closure and payment. Before Under Review, the approved A5 controls continue to apply: a reason, an audit entry, and no locked period touched. |
| **D5** | **Scheduling overlap and monthly absence deduction (former Q10, Q11).** **(a)** A new regular assignment must not overlap a regular assignment of the same employee at a different branch. Work at another branch uses Temporary Coverage or the approved Floating Employee arrangement. The rule applies to new assignments only; historical records are not reinterpreted. **(b)** Monthly-paid absence deduction = **Applicable Monthly Salary ÷ Scheduled Working Days in Payroll Period × Absence Days**. It uses the actual scheduled working days, never a fixed divisor such as 26, and the salary profile applicable on each absence date, split at salary-profile effective-date boundaries. A **Parity Report** comparing the new calculation with the current one is produced before rollout. Absence and unpaid leave never cause a deduction for the same date twice. *(Holiday setting: D11. Partly unscheduled periods: D12. Partly scheduled or partly employed periods: D15; for a fully eligible period this formula is unchanged. D16 does not apply to absence.)* |
| **D6** | **Unused leave payout on termination (former Q39).** Payout = remaining eligible leave days × the approved daily rate. It is shown as a **separate line in Final Payroll**. The leave balance and settlement history are preserved for audit. The balance is never paid or forfeited silently outside the approved settlement process. It applies when the business's termination-settlement setting is "paid" (L26, L31); under "forfeited", a recorded forfeiture entry is written. *(Daily rate: D13, over the eligible dates of D15. Employee without attendance requirement and without a schedule at termination: settlement held for review, D18; the setting applies only after release under D20, never `Forfeit` while held, D19. Employee required to attend without a scheduled working day in the final period: reference-period rate, D22.)* |
| **D7** | **Held-employee payroll processing (former Q40, business part).** The owner approves the **principle**: the other employees' payroll is finalized and paid on time; a held employee's entitlements continue to be calculated; the held employee is finalized and paid later **within the same Payroll Period**; and the held employee's cost stays **Provisional** until released. **This approves the business principle only. It does not approve the technical design and does not authorise R7.** R7.0 must define, and get separate approval for, the items in §18.6.3. |
| **D8** | **Leave and correction policies (former Q44, Q45 (d), Q41).** **(a)** Daily-paid employees are eligible for Unpaid Leave only and get no Paid Annual Leave (or other paid type) in the initial leave system. An approved unpaid-leave day is not an absence; no pay is due for it and no additional absence deduction is applied. Attendance remains required on scheduled working days outside approved leave (confirms L6). **(b)** Carry-over days expire on **31 March following the year in which they were carried over**; the days with the earliest expiry are consumed first (FEFO). This settles L31's wording and matches L26 *("year": D14)*. **(c)** There is no maximum number of correction resubmissions. Every resubmission is a new request linked to the previous one, and the complete history, including rejections and their reasons, is preserved (confirms L35). |

### N — Revision 9 owner decisions D9–D14 (approved 2026-11-06)

These decisions answer the remaining part of Q3 and the Q46 interpretation points (§5) and are now **[A]**. Like
D1–D8, they are separate from the module-boundaries owner decisions D1–D4. Where a decision refines an earlier
rule, that rule's row carries a note.

| ID | Rule |
|---|---|
| **D9** | **Legacy assignments without working days (former Q3, remaining part).** The L9 (1) exception for existing assignments that have no defined working days ends at the end of the **second complete Payroll Period after R4 is deployed**. This deadline is separate from the Not Reviewed deadline: Not Reviewed employees, the second complete Payroll Period after R3.3 is deployed (D1 (1), D10); legacy assignments without working days, the second complete Payroll Period after R4 is deployed. |
| **D10** | **Meaning of "deployment" in D1 (former Q46 (a)).** For the D1 (1) deadline, "after deployment" means after the deployment of **R3.3**, the phase that first creates the Not Reviewed employee records. |
| **D11** | **Public holidays and the absence divisor (former Q46 (b)).** The business-wide public-holiday exclusion setting (L28) also applies to the denominator of the monthly absence deduction (D5 (b)). Approved public holidays excluded by the setting do not count as Scheduled Working Days in the absence divisor. |
| **D12** | **Missing schedule for part of a Payroll Period (former Q46 (c)).** If working days cannot be reliably determined for part of a Payroll Period: no absence deduction is estimated or calculated for the affected unscheduled portion; payroll review shows a clear warning; the Payroll Period may be finalized without an estimated deduction for that portion; absence is calculated normally for the dates with a reliable schedule. *(Price of those dates: D15.)* |
| **D13** | **Daily rate for the termination leave payout (former Q46 (d)).** The D6 payout of unused eligible leave uses the D5 (b) daily rate: **Applicable Monthly Salary ÷ Scheduled Working Days in Payroll Period**, respecting the salary profile applicable to the relevant dates and the approved schedule rules. *(Partial final period: D15. No D13 rate exists for an employee without attendance requirement and schedule: D18 hold; a calculation for them needs formal approval, D20 (1). Employee required to attend without a scheduled working day in the final period: D22.)* |
| **D14** | **Carry-over year (former Q46 (e)).** The "year" in D8 (b) is the calendar year in which the leave days were carried over. Example: days carried over during calendar year 2026 expire on 31 March 2027. The earliest-expiring days are consumed first (FEFO). |

How D9–D14 are applied, and the one point they leave open (Q47), are in §18.7.

### O — Revision 10 owner decision D15 (approved 2026-11-06)

This decision answers Q47 (§5) and is now **[A]**. Like D1–D14, it is separate from the module-boundaries owner
decisions D1–D4. Where it refines an earlier rule, that rule's row carries a note.

| ID | Rule |
|---|---|
| **D15** | **Same eligible dates in numerator and denominator (former Q47).** The daily rate uses the same eligible date range in its numerator and its denominator. **Numerator:** the salary actually attributable to the dates that can reliably be calculated. **Denominator:** the reliable scheduled working days within those same dates. Effective-dated salary profiles are respected and the calculation is split at salary changes. It applies consistently to partial schedules within a Payroll Period, employees joining during a Payroll Period, employees leaving during a Payroll Period, absence deductions, unpaid-leave deductions, and the unused leave payout at termination. Unknown working days are never assumed, salary that is not earned is never counted, and the full monthly salary is never used against a partial-period denominator. *(Employees without a work schedule: D16, Calendar-day Proration, for unpaid leave only.)* |

How D15 is applied, and the points it leaves open (OT1–OT3, Q48), are in §18.8.

### P — Revision 11 owner decision D16 (approved 2026-11-06)

This decision answers Q48 (§5) and is now **[A]**. Like D1–D15, it is separate from the module-boundaries owner
decisions D1–D4. Where it refines an earlier rule, that rule's row carries a note.

| ID | Rule |
|---|---|
| **D16** | **Unpaid leave for employees without a work schedule (former Q48).** Monthly-paid employees who do not have a work schedule, such as central employees, use **Calendar-day Proration** to calculate unpaid-leave deductions. No `ShiftAssignment` or attendance schedule is required solely to calculate their unpaid leave; nothing is divided by zero scheduled working days; no scheduled working days are invented or assumed. This is a specific calculation rule for unpaid leave: it does not change attendance requirements, absence rules or employee classification. Scheduled-day proration (D5 (b), L28, D15) and Calendar-day Proration (D16) stay distinct. *(Scope: D17. Termination payout: D18, released under D20 with the setting of D19.)* |

The exact Calendar-day Proration formula is **not** decided by D16. Its open technical questions (OT4–OT8) and the
point D16 leaves to the owner (Q49) are in §18.9.

### Q — Revision 12 owner decisions D17–D18 (approved 2026-11-06)

These decisions answer Q49 (a) and (b) (§5) and are now **[A]**. Like D1–D16, they are separate from the
module-boundaries owner decisions D1–D4. Where they refine an earlier rule, that rule's row carries a note.

| ID | Rule |
|---|---|
| **D17** | **Scope of Calendar-day Proration (former Q49 (a)).** D16 applies **only** to monthly-paid employees whose employment classification explicitly does not require attendance (`requires_attendance = false`). Central employees without an attendance requirement use Calendar-day Proration for unpaid leave. Employees who require attendance never use D16 as a fallback when their schedule is missing or unreliable; the existing rules for missing or unreliable schedules stay applicable, including payroll-review warnings and finalization blocks where already specified. A `ShiftAssignment` or schedule is never created solely to calculate unpaid leave. This decision does not change any employee's attendance classification. |
| **D18** | **Termination leave payout without a schedule (former Q49 (b)).** For an employee who does not require attendance and has no work schedule when employment ends: the financial settlement of unused leave is **held for HR/Payroll review**; the leave balance is not paid automatically; it is not forfeited, erased or set to zero; the leave balance and the full accrual and settlement history are preserved; the case is recorded as **pending review** until a reliable payout calculation and an authorised resolution are available. This holds the payout; it does not cancel the entitlement. *(Priority over the `Forfeit` setting: D19. Release conditions: D20. Policy snapshot: D21.)* |

How D17 and D18 are applied, and the points they leave open (Q50, OT9), are in §18.10.

### R — Revision 13 owner decisions D19–D20 (approved 2026-11-06)

These decisions answer Q50 (a) and (b) (§5) and are now **[A]**. Like D1–D18, they are separate from the
module-boundaries owner decisions D1–D4. Where they refine an earlier rule, that rule's row carries a note.

| ID | Rule |
|---|---|
| **D19** | **Business-configured termination leave policy and D18 priority (former Q50 (a)).** The unused-leave settlement policy at termination stays configurable in each business's Business Settings, with the options `Pay Out` and `Forfeit`. D18 is a specific protective exception: for an employee who does not require attendance and has no schedule, the unused-leave settlement stays held; the balance is not forfeited, erased or zeroed while the settlement is pending; the business's `Forfeit` setting does not automatically override the hold. The business setting itself stays available and is not removed or globally changed. Once the D18 hold is resolved through the approved process (D20), the business's configured termination policy is applied; `Forfeit` is never automatically converted into `Pay Out`. *(Policy version: the D21 snapshot.)* |
| **D20** | **Conditions for releasing a held settlement (former Q50 (b)).** A D18 held termination settlement may be released only after **all** of the following are completed: (1) a reliable payout calculation for employees who do not require attendance has been formally approved; (2) HR has reviewed the employee's employment details and leave balance; (3) Payroll has reviewed and approved the settlement amount; (4) the business's configured termination policy (`Pay Out` or `Forfeit`) is applied. Until all required conditions are met: the leave balance stays preserved; the settlement stays pending; it is not paid automatically; it is not forfeited or erased; the full accrual, hold, review and settlement history is preserved. *(Policy applied at release: the D21 snapshot. Who may record (2) and (3): the configured permissions, D23.)* |

How D19 and D20 are applied, and the points they leave open (Q51, OT9), are in §18.11. The payout calculation named
in D20 (1) is not designed in this plan; it needs its own formal approval.

### S — Revision 14 owner decision D21 (approved 2026-11-06)

This decision answers Q51 (§5) and is now **[A]**. Like D1–D20, it is separate from the module-boundaries owner
decisions D1–D4. Where it refines an earlier rule, that rule's row carries a note.

| ID | Rule |
|---|---|
| **D21** | **Business termination-policy snapshot (former Q51).** For a held termination leave settlement under D18: the business termination policy is configured independently in each business's Business Settings; the applicable policy is the policy that was in force on the employee's **employment end date**; an **immutable snapshot** of the business setting as of that date is captured, preserving which policy applies, its effective date and the business identity, so that the policy applied can be audited; if the setting later changes from `Forfeit` to `Pay Out`, or the reverse, the existing held settlement does not change; once the D20 release conditions are satisfied, the snapshotted policy is applied; `Forfeit` is never converted into `Pay Out`; a later settings change never silently rewrites an existing termination settlement. The termination-policy snapshot is a separate historical fact from the salary-profile snapshot and the leave-balance snapshot. |

How D21 is applied is in §19.1 and §19.3 (OT9).

### T — Revision 15 owner decisions D22–D23 (approved 2026-11-06)

These decisions answer Q52 and Q53 (§5) and are now **[A]**. Like D1–D21, they are separate from the
module-boundaries owner decisions D1–D4. Where they refine an earlier rule, that rule's row carries a note.

| ID | Rule |
|---|---|
| **D22** | **Termination daily rate when no scheduled working days exist (former Q52).** When an employee who is required to attend has no scheduled working days in the final Payroll Period, the termination settlement uses the **last preceding reliable Payroll Period in which the employee had scheduled working days** as the **reference period** for calculating the daily rate. The settlement record preserves the reference Payroll Period and the rate used, so the calculation stays auditable and reproducible. Calendar-day Proration is not used as a fallback for employees who are required to attend; no schedule is invented and no working days are assumed; the distinction between employees who are and are not required to attend is preserved. D16 and D17 are unchanged. *(Scope: D24. No reference period: D25. Salary: D26. Reliable reference period: D27.)* |
| **D23** | **HR review and Payroll approval permissions (former Q53).** The Super Admin controls permission assignment and may grant the HR review permission and the Payroll approval permission of a held settlement (D20 (2) and (3)) to the same person or to two different people. The system enforces the permissions actually configured by the Super Admin; it does not impose a mandatory separation-of-duties rule requiring two different people. The permission definitions are unchanged: HR review `manage_employees`, Payroll approval `finalize_payroll`. No permission is added and the permission model is not changed. |

How D22 and D23 are applied, and the details D22 leaves open (Q54), are in §19.1–§19.3. *(Q54 decided in
revision 16 as D24–D27, §2 U.)*

### U — Revision 16 owner decisions D24–D27 (approved 2026-11-06)

These decisions answer Q54 (§5) and are now **[A]**. Like D1–D23, they are separate from the module-boundaries
owner decisions D1–D4. They refine D22, whose row carries a note.

| ID | Rule |
|---|---|
| **D24** | **D22 scope clarification.** D22 applies when the employee has no reliably scheduled working days within their **actual employment dates** in the final Payroll Period. Scheduled days after the employment end date do not count. |
| **D25** | **No reference period (former Q54 (a)).** If no preceding reliable Payroll Period with scheduled working days exists, the termination leave settlement is kept **pending HR/Payroll review**. The balance is not paid, forfeited, zeroed or silently discarded. |
| **D26** | **Salary used for the daily rate (former Q54 (b)).** The D22 daily rate uses the salary in force on the employee's **employment end date**, not the salary from the reference Payroll Period. |
| **D27** | **Reliable reference period (former Q54 (c)).** A preceding Payroll Period qualifies as reliable if it contains **at least one reliably scheduled working day**. The rate is calculated using **only the reliably scheduled dates**. Unscheduled dates are not treated as working days and no schedule is invented. |

**Settlement record (D22–D27):** the settlement record preserves enough information to audit and reproduce the
calculation, including the reference Payroll Period, the employment end-date salary used, the reliably scheduled
dates used in the calculation, and the daily rate and its calculation inputs.

How D24–D27 are applied, and the point D25 leaves open (Q55), are in §19.1–§19.3.

### V — Revision 17 owner decisions D28–D34 (approved 2026-11-08; D33 with the R3.1 hardening; D34 on 2026-11-10)

These decisions settle points of R3.1 (§6.6, §6.8, §8, §18.2 G2 / G10) and are now **[A]**. Like D1–D27, they are
separate from the module-boundaries owner decisions D1–D4. None of them changes `log_audit`, `log_audit!`,
`write_audit_log!` or `report_audit_failure`, or any of their callers; R3.1 uses a separate, explicit opt-in API.

| ID | Rule |
|---|---|
| **D28** | **Last-resort logging.** When writing the durable pending audit record itself fails, the last-resort log line and error report may carry the **full payload**, including financial and personal values. This applies **only** to that R3.1 fallback (§6.6 step 5). The global audit-failure reporting (ids and keys, no values) is unchanged, and the BUG-003 decision on whether logs may carry values stays open. |
| **D29** | **Audit timestamp.** A delivered Audit Log entry's `created_at` is the time of the **original attempt**, not the later delivery time. Delivery and attempt times are kept separately on the durable record and its attempt log. |
| **D30** | **Business dashboard visibility.** Holders of `monitor_audit_failures` see operational information only: event status, operational failure information, attempt count and timestamps, escalation status. They never see the payload or any financial or personal value from it. |
| **D31** | **Dormant first release.** R3.1 may ship without a producer; the dashboard stays empty until R3.4 introduces the rejected-attempt producer. No existing `log_audit` caller is connected in R3.1. |
| **D32** | **Escalation notification.** An escalated event is shown on the business dashboard, and the sidebar shows a badge with the number of unresolved escalated events. The count is business-scoped and permission-protected, and refreshes when a page loads. No external notification channel. |
| **D33** | **Whole delivery-transaction failure** (R3.1 hardening, 2026-11-08). When the delivery transaction fails as a whole, it is rolled back and the attempt is recorded as a failed attempt in a separate transaction: retry counters, next retry time and escalation state are updated and the attempt row is appended. If that independent transaction cannot be committed either (the database is still unavailable), the attempt is **not** presented as recorded; the pending event is preserved unchanged and the sweeper retries it once the database is available. The pending event is never lost because recording an attempt failed. |
| **D34** | **Log and payload retention** (R3.1, approved 2026-11-10). (1) Docker container logs use the `json-file` limits `max-size: 20m` and `max-file: 5`: at most 100 MB of logs per container. (2) The full payload stored in the database is **not** deleted automatically as part of R3.1; no automatic database retention or deletion job is authorised. (3) The full payload is **never** sent automatically to Sentry or any other external error reporter. (4) The Docker rotation settings take effect once the containers are recreated. D34 does not change D28, the D28 clarification or the never-delete rule for pending events (L34). |

**D28 clarification (R3.1 hardening, 2026-11-08).** The owner's hardening authorisation limits D28 further: the full
payload may be written to the **last-resort log line only**. It is never sent automatically to a third-party error
reporter; the error report of that fallback carries identifiers, keys and error classes only. D28 still does not
change `log_audit`, `log_audit!` or the global audit-failure reporting, and does not authorise showing the payload to
dashboard users. Operational controls (log rotation, access, retention, error-reporter review):
`docs/durable_audit_operations.md` §4; the approved retention policy is D34.

---

## 3. Current behaviour and code evidence **[C]**

### 3.1 Attendance requirement and assignment paths

| Finding | Evidence |
|---|---|
| Flag `users.requires_shift_assignment` boolean NOT NULL default true; no validation, callback or audit on change | `db/migrate/20260930100000_add_requires_shift_assignment_to_users.rb:7`; `db/schema.rb:2430`; `app/controllers/admin/users_controller.rb:65-86` |
| Only reader: `Shifts::AssignmentEligibility#shift_based` | `app/services/shifts/assignment_eligibility.rb:51-53` |
| Enforced only on single create, regular + floating | `app/controllers/shift_assignments_controller.rb:103-114`, `:389-397` |
| Not enforced: temporary coverage | `app/controllers/shift_assignments_controller.rb:390` |
| Not enforced: bulk assign / bulk preview | `app/controllers/shift_assignments_controller.rb:279-295`, `:209` |
| Not enforced: API | `app/services/shifts/assigner.rb:17-25` |
| Not enforced: templates | `app/services/scheduling/template_applier.rb:49` |
| Not enforced: edit | `app/controllers/shift_assignments_controller.rb:124-133` |
| Single choke point every path uses: model validations | `app/models/shift_assignment.rb:33-50` |
| Overlap rule is **per branch**: concurrent regular assignments at different branches are allowed (unless fixed clock times clash) | `app/models/shift_assignment.rb:283-305`, `:319` |
| Floating is exclusive of every other assignment | `app/models/shift_assignment.rb:266-274` |
| Resolver: one winner per date — temporary coverage, then latest `effective_from`, then highest id | `app/services/shifts/assignment_resolver.rb:31`, `:60` |
| New employees get the DB default (true) via `Accounts.build` and data-request approval | `app/services/organization_access/accounts.rb:42-48` |
| `ShiftAssignment.current` uses the server date `Date.current`, not the business day | `app/models/shift_assignment.rb:65` |
| No employment termination date exists; `users` has `hire_date` only; leaving = account deactivation (`Accounts.toggle_active!`) | `db/schema.rb` (users); `app/services/organization_access/accounts.rb:80` |

### 3.2 Schedules, attendance and absence

| Finding | Evidence |
|---|---|
| `shifts` store times/hours only; `shift_assignments` store dates, kind, branch — **no working weekdays** | `db/schema.rb` (`shifts`, `shift_assignments`) |
| Template entries have a `weekday` column the previewer and applier never read | `app/services/scheduling/template_previewer.rb:50-57`; `app/services/scheduling/template_applier.rb:49-53` |
| No holiday table or calendar exists | `db/schema.rb` |
| Check-in (web and API) requires a branch with a current assignment | `app/controllers/attendance_controller.rb:6-9`; `app/services/attendance/check_in_service.rb:20-25`, `:52-54` |
| Biometric punch without an assignment for the date → `rejected_no_assignment`; device branch kept on the punch log (PR #110) | `app/services/attendance/punch_service.rb:16-25`, `:101-104` |
| Lateness / early leave from the record's assignment shift; 0 without one | `app/services/attendance/derived_fields.rb:27-38` |
| Absence (monthly part) only if an assignment of any kind is active on the **first day** of the monthly part; period `working_days` − complete days | `app/services/payroll/entry_calculator.rb:298-311`, `:344-347` |
| Consequences: an assignment ending mid-month still counts the days after it ended; one starting later suppresses absence for the whole month | same |
| `period.working_days` = `businesses.working_days_per_month` | `app/services/payroll/period_generator.rb:46`, `:53` |
| Payroll population: active employees + anyone with attendance, adjustments or advances; flag not read | `app/services/payroll/period_generator.rb:80-85` |
| No `absent` attendance records are ever created | `app/services/attendance/status_backfill.rb:35` |

### 3.3 Costs, allocation and finalization

| Finding | Evidence |
|---|---|
| Insurance attribution: last assignment of the period; floating → `unallocated`; no assignment → first branch of any type | `app/services/payroll/employer_insurance_cost.rb:26-58` |
| Insurance expense created already **approved** at finalization; floating share as a separate `unallocated: true` expense | `app/services/finance/payroll_insurance_expense.rb:48-134` |
| Salary is never an `Expense`; reports compute it live from `PayrollEntry` of **any** period status; floating → Unallocated; no assignment → first **sales** branch | `app/services/finance/reports/expense_sources.rb:40-54`, `:153-192` |
| Finalization refusals inside the transaction, then the contract call | `app/services/payroll/approver.rb:62-96`, `:114-118` |
| Contract today: `period_finalized(period:, actor:, employer_insurance_total:, employer_insurance_by_branch:, employer_insurance_unallocated:)`, `period_reopened(period:, actor:, reason:)` | `app/services/payroll/finalization_effects.rb:17-26`; `app/services/finance/payroll_finalization_effects.rb:17` |
| Locked periods are `finalized` and `paid` only | `app/models/payroll_period.rb:71-77` |
| Manual expenses: one branch or a complete split; Σ 100 %, exact amounts at 2 dp, no duplicate branch — validated on every save including draft | `app/models/finance_sales/expense.rb:203-256` |
| Remainder-on-last-row rounding duplicated in three places | `app/services/finance/allocation_calculator.rb:67-78`; `app/services/finance/payroll_insurance_expense.rb:151-163` |
| Allocation rows: model checks same business only; active / scope enforced by the picker only | `app/models/finance_sales/expense_allocation.rb:20-24`; `app/controllers/finance/base_controller.rb:107-116` |
| Recurring templates: branch optional, allocations not validated; incomplete templates fail at generation | `app/models/finance_sales/recurring_expense.rb:24-31`; `app/services/finance/recurring_expense_generator.rb:59-80` |
| Legacy branch-less unsplit expenses reported as "unattributed" | `app/services/finance/reports/expense_details.rb:315-320` |
| Unallocated generated / shown in: `PayrollInsuranceExpense#build_unallocated_expense`, `Expense.business_level`, `ExpenseSources#unallocated_*`, `BranchProfitability#unallocated_row`, `ExpenseSummary#unallocated_row`, `ExpenseDetails` groups, `Reports::Table#unallocated` + `_table.html.erb` + `CsvExporter`, `Finance::DashboardController`, `PayrollDashboardController:130`, `Payroll::RecommendationEngine:236` | grep `unallocated` under `app/` |

### 3.4 Permissions **[C]**

Permission groups, scopes and dependencies live in `app/models/organization_access/permission_role.rb`:
`PERMISSION_GROUPS` (`expense_administration` at `:77`), `BRANCH_SCOPABLE_PERMISSIONS` (`:179`, resolved by
`BranchScope`), `SCOPABLE_PERMISSIONS` (`:225`), `PERMISSION_DEPENDENCIES` (`:275`), scope options
self / branch / area / business.

### 3.5 Related deferred bugs (`docs/quality/deferred-bugs.md`)

BUG-013 (attendance editable in a finalized month), BUG-040 (grace depends on attendance source), BUG-044 (device
branch reassignment unaudited — the reason J excludes worked-branch allocation), BUG-045 (draft regenerate drops data).

### 3.6 Salary type, requirement writers, leave and audit (for L1–L9)

| Finding | Evidence |
|---|---|
| Salary type is `SalaryProfile.salary_type` (`monthly` / `daily`), AP-owned; effective-dated: the profile in force on a date is the latest `effective_from` on or before it, ties to the highest id; `active` marks the latest entered profile, so a future-dated daily profile can already exist | `app/models/salary_profile.rb:4-8`, `:37-51`; `docs/architecture/module-boundaries.md:239-240` |
| Profile guards: historical profiles immutable; a correction cannot move `effective_from` onto or past the next profile; no cross-domain validation | `app/models/salary_profile.rb` (`immutable_if_historical`, `effective_from_before_next_profile`) |
| New profile (admin and API): `Salary::ProfileUpdater` — one transaction (deactivate, `create!`, `log_audit`), payroll recalculation **after** commit, errors swallowed; no lock | `app/services/salary/profile_updater.rb:34-61`; `app/controllers/admin/salary_profiles_controller.rb:11-22`; `app/controllers/api/v1/salary_profiles_controller.rb:28-37` |
| In-place correction: `Salary::ProfileCorrector`; the **admin** path permits `salary_type` and `effective_from`, the API path excludes both; no lock | `app/services/salary/profile_corrector.rb:34-60`; `app/controllers/admin/salary_profiles_controller.rb:30-41`, `:55-58`; `app/controllers/api/v1/salary_profiles_controller.rb:43-56` |
| Other salary-profile writers: dev seeds only (`SalaryProfile.create!`); no import, job, data-request or destroy path | `db/seeds.rb:216`; `app/services/employee_data_requests/employee_attributes.rb:7-9` |
| Daily pay = rate × complete attendance days; the entry's `salary_type` is the type in force on the period's last day | `app/services/payroll/entry_calculator.rb:79-88`; `app/services/payroll/basic_salary_calculator.rb:77` |
| `requires_attendance` and `employee_attendance_requirements` do not exist anywhere in code, schema or specs | grep at baseline |
| Employee creation has no service: `Admin::UsersController#create` assigns attributes and calls `@user.save`; data-request approval builds the user through `EmployeeDataRequests::EmployeeAttributes.build_user` | `app/controllers/admin/users_controller.rb:22-42`; `app/services/employee_data_requests/employee_attributes.rb:40-46` |
| Employment flags are mass-assigned through `UserPolicy::EMPLOYMENT_ATTRIBUTES` (no service, no audit) | `app/policies/user_policy.rb:12-15` |
| `users.hire_date` is nullable; no employment start date is otherwise stored | `db/schema.rb:2423` |
| **No leave concept exists:** request types are `salary_advance`, `late_permission`, `early_leave`, `punch_correction`; absence calculation reads no leave; no leave type, balance or entitlement table exists | `app/models/employee_request.rb:11`; `app/services/payroll/entry_calculator.rb:298-347`; `db/schema.rb` |
| `EmployeeRequest` (and so the existing request/approval workflow) is Workforce-owned — the natural home for L15 leave requests | `docs/architecture/module-boundaries.md:218`, `:322` |
| A `notifications` table exists in the schema (per user: `user_id` NOT NULL, `event_type`, `title`, `body`, `severity`, `category`, `data` jsonb, `read_at`; no `business_id`), but no model, service, controller or route in `app/` or `config/routes.rb` uses it, and there is no administration notifications dashboard; the only verified failure-reporting path is `Rails.error.report` (used by `AuditLoggable`) — L29's dashboard and its integration are new work | `db/schema.rb:967`; grep under `app/` and `config/routes.rb`; `app/controllers/admin/` |
| Payroll permissions that exist today (group `payroll`): `view_payroll`, `view_draft_payroll`, `view_payroll_analytics`, `view_payroll_audit_log`, `create_payroll`, `regenerate_payroll`, `submit_payroll_review`, `complete_branch_review`, `approve_payroll_items`, `manage_payroll_overrides`, `manage_payroll_deduction_waivers`, `manage_payroll_addition_cancellations`, `finalize_payroll`, `pay_payroll`, `reopen_payroll`, `delete_payroll`; every other payroll permission depends on `view_payroll` — the permission L30 uses for Payroll's review. `manage_historical_payroll_corrections` and `approve_historical_payroll_corrections` do not exist | `app/models/organization_access/permission_role.rb:27-32`, `:280-303` |
| Branches already record a `branch_manager_id` and an `area_manager_id`; `area_manager` is a permission-role archetype — the existing data L27's routing (branch manager → area manager) can resolve from | `app/models/branch.rb:25`; `db/schema.rb:321`; `app/models/organization_access/permission_role.rb:5` |
| A shared self-approval guard exists (`Approvals::SelfApproval`) — a precedent for keeping the executor and the approver of an L30 correction different people | `app/services/approvals/self_approval.rb` |
| Payroll finalization is **per period**: `Payroll::Approver#advance` moves the whole period to `finalized` (one `update!` on the period) after period-wide refusals; entries have only `draft` / `approved` / `disputed`, with no per-entry finalization or hold — L32's per-employee block has no existing mechanism | `app/services/payroll/approver.rb:39-103`; `app/models/payroll_entry.rb:11` |
| "Super Admin" in the code means the **business owner** (e.g. "Super Admin (business owner) is never blocked…"); every user belongs to one business; there is no platform-level operator role. L34's system-wide System Administrator has no existing identity | `app/policies/till_deposit_policy.rb:7`; `app/policies/till_handover_policy.rb:21`; `CLAUDE.md` → Multi-tenancy |
| Business owners implicitly hold **every** permission (`ApplicationPolicy`), so an owner holds both L35 correction permissions; separation of duties and the Super Admin fallback cannot rely on permission checks alone | `CLAUDE.md` → Multi-tenancy, Authorization |
| The admin namespace is not a system-administrator area: `Admin::BaseController#require_admin_access!` admits any user with one of 13 ordinary permissions (e.g. `view_payroll`, `view_employees`) | `app/controllers/admin/base_controller.rb:7-18` |
| `notifications` is classified Infrastructure, **Legacy / unused** ("model removed in `20c7430`; do not delete now") | `docs/architecture/module-boundaries.md:366`, `:687` |
| Role archetypes are `branch_manager`, `area_manager`, `accountant`, `employee` — no HR or Finance Manager archetype for L35's default assignments | `app/models/organization_access/permission_role.rb:5`, `:118` |
| `hire_date` is mass-assigned through `UserPolicy::EMPLOYMENT_ATTRIBUTES` with no reason or audit — L31's service-date correction needs a dedicated path | `app/policies/user_policy.rb:12-15` |
| Monthly salary is already priced per profile segment within a period and recorded in `PayrollEntry#salary_breakdown` (relevant to L23 when the salary changes mid-month) | `app/services/payroll/basic_salary_calculator.rb:4`, `:77` |
| `log_audit` (fail-open: reports through `Rails.error.report`, returns nil) and `log_audit!` (raises `AuditWriteFailed`) exist. The write uses `AuditLog.transaction(requires_new: true)` — a savepoint inside the caller's transaction when there is one, its own transaction when called outside any. Nothing retries a failed write — L14's alert-and-retry / recovery is new work | `app/models/concerns/audit_loggable.rb` (`log_audit`, `log_audit!`, `report_audit_failure`); `CLAUDE.md` → Services |
| Advisory transaction locks are an existing pattern (employee code, branch lifecycle, duplicate data requests) | `app/models/user.rb:305-313`; `app/models/daily_reconciliation.rb:549-560`; `app/services/employee_data_requests/duplicate_guard.rb` |
| WF-defined, AP-implemented contract precedents, registered by initializer | `Shifts::AttendanceUsage` (`app/services/shifts/attendance_usage.rb`, `config/initializers/shift_attendance_usage.rb`); `Employee::ProfilePanels` (`config/initializers/employee_profile_panels.rb`) |
| `log_audit` writes in its own savepoint **inside** the caller's transaction (CLAUDE.md, BUG-003), so an entry written before a rollback is rolled back with it — a rejected-attempt entry needs a different placement (§6.6) | `CLAUDE.md` → Services; `docs/quality/deferred-bugs.md` BUG-003 |

---

## 4. Approved decisions, their IDs, and superseded plan items

### 4.1 Decision register

| Original question | Resolved by |
|---|---|
| D-A1 transition state | A2 |
| D-A2 source of truth | A3 |
| D-A3 undefined schedules | A7 |
| D-A4 backdating | A5 |
| D-A5 rotation | A8 |
| D-A6 daily-paid exempt pay | A9 (no exemption exists) |
| D-A7 steward of the requirement | A12 (Workforce) |
| D-A8 holidays | A10 |
| D-A9 approval step | A5 (direct, `manage_employees`) |
| D-B1 central identification | B |
| D-B2 required employee without assignment | C |
| D-C1 insurance follows salary | E |
| D-C2 unfinalized periods in reports | F |
| D-C3 rule management permission | G |
| D-C4 existing Unallocated rows | H |
| D-C5 central salary in branch view | I |
| D-D floating allocation method | J |
| Contract extension | K |
| Q1 (rev. 1) legacy assignment without weekdays vs C | L9 |
| Q2 (rev. 1) daily-paid check across the WF/AP boundary | L1, L2 |
| Q-A initial history row, backfill, unreviewed employees | L4 |
| Q-B whole-history invariant and locked payroll | L5 |
| Q-C reject only; salary conversion is a separate operation | L2, L7 |
| Q-D rejected attempts audited | L8 |
| Q-E lock strategy | L3 (Workforce-owned advisory transaction lock) |
| Q-F admin correction of `salary_type` / `effective_from` | L2 (kept, validated) |
| Daily-paid leave (owner clarification) | L6 |
| Q15 (rev. 2) value of the requirement row at employee creation | L10 |
| Q16 (rev. 2) (a) backfill scope, (b) effective date, (c) Not Reviewed vs daily profile | L11, L12, L13 |
| Q17 (rev. 2) rejected-attempt audit placement and failure policy | L14 |
| Q18 (rev. 2) leave ownership | L15 |
| Q19 (rev. 2) monthly-paid leave policy | L16 |
| Q20 (rev. 2) historical conflicts and the corrective process | L17 |
| Q21 (rev. 3) employment start date at creation | L18 |
| Q22 (rev. 3) valid `hire_date` and reliable records | L19 |
| Q23 (rev. 3) audit retry, recovery and alerting | L20 (alert channel: L29) |
| Q24 (rev. 3) leave approved for dates in a locked period | L21 |
| Q25 (rev. 3) annual leave entitlement | L22 (balance rules: L26; proration and other details: Q34) |
| Q26 (rev. 3) monthly unpaid-leave pricing | L23 (denominator details: L28) |
| Q27 (rev. 3) Historical Violation lifecycle | L24 (permissions: L30) |
| Q28 (rev. 3) HR exception-list employees | L25 (deadline: Q3 → D1 (1)) |
| Q29 (rev. 4) annual-leave balance rules | L26 (proration, negative balances and other details: Q34) |
| Q30 (rev. 4) leave approval and cancellation | L27 (mechanics: Q36) |
| Q31 (rev. 4) unpaid-leave denominator details | L28 (whether a flagged case blocks finalization: Q35) |
| Q32 (rev. 4) audit-failure alert channel | L29 (recipients and thresholds: Q37) |
| Q33 (rev. 4) Historical Violation permissions | L30 (permission configuration: Q38) |
| Q34 (rev. 5) leave-balance details | L31 (termination payout amount: Q39 → D6) |
| Q35 (rev. 5) flagged unpaid-leave case at finalization | L32 (per-employee mechanism: Q40 → D7 principle; design R7.0) |
| Q36 (rev. 5) leave-approval mechanics | L33 (operational details: Q45 → **[T]** and D8 (b); daily-paid paid types: Q44 → D8 (a)) |
| Q37 (rev. 5) audit-failure alert details | L34 (System Administrator identity: Q42 → D1) |
| Q38 (rev. 5) correction-permission configuration | L35 (resubmission limit: Q41 → D8 (c); role mapping: Q43 → **[T]**; Super Admin identity: Q42 → D1) |
| Q3 (rev. 1) review and transition deadline | D1 (1) (review deadline; reference point D10); D9 (end of the L9 (1) legacy-schedule exception) |
| Q4 (rev. 1) holiday calendar | D3 (business-wide); owner and permission **[T]** (§18.1) |
| Q9 (rev. 1) payroll states blocking backdating | D4 |
| Q10 (rev. 1) concurrent regular assignments at different branches | D5 (a) |
| Q11 (rev. 1) price of a monthly absent day | D5 (b) |
| Q12 (rev. 1) central and floating aggregate label | D2 |
| Q39 (rev. 6) termination payout amount | D6 (daily rate: D13) |
| Q40 (rev. 6) per-employee finalization mechanism | D7 (business principle); technical design: the R7.0 gate (§18.6.3) |
| Q41 (rev. 6) resubmission limit | D8 (c) |
| Q42 (rev. 6) identities | D1 (2)–(4) for (a) and (b); (c) **[T]** (§18.1) |
| Q44 (rev. 6) daily-paid paid leave types | D8 (a) |
| Q45 (d) (rev. 6) carry-over shortly before 31 March | D8 (b) (year: D14) |
| Q46 (rev. 8) interpretation points (a)–(e) | D10, D11, D12, D13 and D14 respectively ((c) differs from the revision 8 recommendation) |
| Q47 (rev. 9) rate for partly scheduled or partly employed periods | D15 (technical points OT1–OT3, §18.8.3) |
| Q48 (rev. 10) unpaid leave for employees without a schedule | D16 (formula details OT4–OT8, scope and payout Q49, §18.9) |
| Q49 (rev. 11) (a) scope of D16, (b) payout without a schedule | D17, D18 (forfeited setting and eventual payout calculation Q50; resolution path OT9, §18.10) |
| Q50 (rev. 12) (a) forfeited setting under D18, (b) eventual payout calculation | D19, D20 (setting version at release Q51; release steps OT9, narrowed; §18.11) |
| Q51 (rev. 13) setting version at release | D21 (snapshot at the employment end date; §19.1, §19.3) |
| Q52 (rev. 14) payout rate for a required leaver without a scheduled day | D22 (reference period; details Q54 → D24–D27) |
| Q53 (rev. 14) same person for D20 (2) and (3) | D23 (configured permissions; no mandatory two-person rule) |
| Q54 (rev. 15) details of D22: (a) no reference period, (b) salary, (c) reliable period | D25, D26, D27; scope clarified by D24 (pending-case resolution Q55, §19.2) |
| Q5–Q8, Q13, Q14, Q43, Q45 (a)(b)(c)(e)(f)(g)(h) | Technical decisions **[T]** (§18.1, revision 7), not owner decisions |

### 4.2 Allocation rules apply to whom **[A]/[P]**

Derived from B, C, J: a Cost Allocation Rule is **required** for central employees (B) and floating employees (J)
and **not** required for employees whose cost is attributed directly through a branch assignment. A rule never
substitutes for missing attendance data (C). **[P]** The existing approved attribution rule — "the employee's last
assignment state in the period decides the whole period's cost attribution, no proration" — is kept and extended:
last state branch-assigned → that branch; last state floating → the floating employee's rule; last state central
(no assignment, not required) → the central employee's rule. See Q6.

### 4.3 Conflicts with `floating-employees-implementation-plan.md` (the approved rules win)

| # | Earlier item | Superseded by | Effect |
|---|---|---|---|
| X1 | §12 Release 1: `AssignmentEligibility#shift_based` keeps only the owner exclusion, "no replacement checkbox" | A4 | Eligibility and the model validation use the effective-dated requirement |
| X2 | §7 / P12 rows "Daily exempt — scheduled dates" and "Daily exempt — undefined dates" | A9, L2 | Both rows removed; daily-paid employees always require attendance. The other "exempt daily" mentions of that plan (§7 parity sentence, §11 missing-schedule ordering, §13 test matrix) fall with them |
| X3 | §1.2 / §6: `users.requires_attendance` as the nullable record of truth, "no backfill" | A3 | History table is the source of truth; the column is a cache |
| X4 | §1.2 "Mixed-schedule month — hybrid: undefined dates use the legacy rule"; §7 row "Monthly required — undefined dates (legacy)" | A6, A7 | Undefined dates: no deduction + warning; no 26-day fallback |
| X5 | Phase 13: unallocated salary/insurance for employees without assignments | B, C | Withdrawn: central → rule; required without assignment → finalization blocked |
| X6 | Decision 6b (implemented): Unallocated insurance expense and Unallocated salary line for floating employees | J, H | New periods: fixed-percentage rule; existing rows kept, labelled historical |
| X7 | §7 row "No assignment: legacy + warning" | B, C | Not required → central rule; required → blocks finalization |
| X8 | §7 row "Floating: … costs Unallocated" | J | Floating costs follow the rule |

Unchanged and still binding: P9 (resolver precedence, weekdays from the winner only), strategy A (never change a
schedule overlapping a locked period; end + successor), P10 (template weekday multi-select), the salary-advance
decisions P1–P8, the central payroll review (6a), and the "last assignment decides cost attribution" rule (§4.2).

---

## 5. Remaining unresolved questions **[Q]**

**Resolved since revision 1** (now approved decisions, no longer open): Q1 → L9; Q2 → L1/L2; and the follow-up
questions Q-A → L4, Q-B → L5, Q-C → L2/L7, Q-D → L8, Q-E → L3, Q-F → L2 (§4.1). **Resolved in revision 3:** Q15 → L10;
Q16 → L11/L12/L13; Q17 → L14; Q18 → L15; Q19 → L16; Q20 → L17. **Resolved in revision 4:** Q21 → L18; Q22 → L19;
Q23 → L20; Q24 → L21; Q25 → L22; Q26 → L23; Q27 → L24; Q28 → L25. **Resolved in revision 5:** Q29 → L26;
Q30 → L27; Q31 → L28; Q32 → L29; Q33 → L30. No contradiction between approved decisions remains open. Q3–Q14 below
are unchanged and unresolved (Q3 includes the transition deadline that L25 leaves open). **Resolved in revision 6:**
Q34 → L31 (except the termination payout amount, carried forward as Q39); Q35 → L32; Q36 → L33; Q37 → L34;
Q38 → L35. Q39–Q45 are what L31–L35 leave open; each carries a conservative recommendation **[P]** that is not an
approved decision and needs owner confirmation. Q34–Q38 are not reopened.

**Revision 7 classification (§18.1):**
* **Owner business decisions:** Q3, Q9, Q11, Q12, Q39, Q41 and Q44, plus the business part of Q4, Q10, Q40,
  Q42 (a)/(b) and Q45 (d). They are consolidated as D1–D8 in §18.5.
* **Technical:** Q5, Q6, Q7, Q8, Q13, Q14, Q43 and the technical parts of the mixed questions. Their recommendations
  below become **[T]** decisions (§18.3), and the owner is not asked about them.
* The table below is kept unchanged for traceability.

**Revision 8 (owner decisions D1–D8, §2 M):**
* **Resolved:**
  * Q3's review deadline → D1 (1);
  * Q4 → D3 (owner and permission **[T]**);
  * Q9 → D4;
  * Q10 → D5 (a);
  * Q11 → D5 (b);
  * Q12 → D2;
  * Q39 → D6;
  * Q40 → D7 (business principle; the design is the R7.0 gate);
  * Q41 → D8 (c);
  * Q42 (a)/(b) → D1;
  * Q44 → D8 (a);
  * Q45 (d) → D8 (b).
* **Still open (owner) at revision 8, both resolved in revision 9:**
  * Q3, only the end of the L9 (1) legacy-schedule exception;
  * Q46 (a)–(e), new interpretation points.
* Technical decisions **[T]** are unchanged.

**Revision 9 (owner decisions D9–D14, §2 N):**
* **Resolved:**
  * Q3, the end of the L9 (1) legacy-schedule exception → D9, so Q3 is now fully resolved;
  * Q46 (a) → D10, (b) → D11, (c) → D12, (d) → D13, (e) → D14. D12 differs from the (c) recommendation below.
* **New open question:** Q47, raised by the revision 9 consistency check (§18.7.2).
* Q46's text and recommendations are kept for traceability.

**Revision 10 (owner decision D15, §2 O):**
* **Resolved:** Q47 → D15. The owner's wording states the principle; the §5 Q47 recommendation is kept for
  traceability, and how D15 is applied is in §18.8.
* **New open owner question:** Q48 (§18.8.2 K30).
* **Open technical issues:** OT1–OT3 (§18.8.3). They are engineering decisions, not owner questions, unless a
  resolution would change a fully eligible period's result or create a business rule.

**Revision 11 (owner decision D16, §2 P):**
* **Resolved:** Q48 → D16 (Calendar-day Proration for unpaid leave of monthly-paid employees without a work
  schedule). Q48's options and recommendation below are kept for traceability; D16 is none of the three options
  listed there.
* **New open owner question:** Q49 (§18.9.2 K37, K41).
* **Open technical questions:** OT4–OT8 (§18.9.3), for R7's design review, under the same rule as OT1–OT3.

**Revision 12 (owner decisions D17–D18, §2 Q):**
* **Resolved:** Q49 (a) → D17, matching the (a) recommendation; Q49 (b) → D18, a hold for review, which goes
  further than the (b) recommendation (Flagged for Review) by recording a pending settlement and forbidding
  forfeiture or zeroing.
* **New open owner question:** Q50 (§18.10.2 K50, K51).
* **New open technical question:** OT9 (§18.10.3). OT1–OT8 stay open.

**Revision 13 (owner decisions D19–D20, §2 R):**
* **Resolved:** Q50 (a) → D19, which confirms the (a) recommendation (held under both settings) and adds that the
  configured setting applies after release, with `Forfeit` never converted into `Pay Out`; Q50 (b) → D20, four
  release conditions. D20 does not supply the payout calculation: it makes its formal approval a release condition.
* **New open owner question:** Q51 (§18.11.2 K62).
* **Open technical question narrowed:** OT9 (§18.11.3). OT1–OT8 stay open.

**Revision 14 (owner decision D21, §2 S; consolidation, §19):**
* **Resolved:** Q51 → D21, matching the Q51 recommendation (the setting in force on the employment end date) and
  adding that it is captured as an immutable snapshot.
* **New open owner questions:** Q52 (from OT1) and Q53 (from OT9), the only business policies the consolidation found
  that no approved rule settles (§19.2).
* **Technical questions:** OT2–OT8 resolved; OT9 resolved except Q53 (§19.3).

**Revision 15 (owner decisions D22–D23, §2 T):**
* **Resolved:** Q52 → D22: a reference period, the last preceding reliable Payroll Period in which the employee had
  scheduled working days, in the direction of the Q52 recommendation; the recommendation's salary-profile part is not
  part of D22 (Q54 (b)). Q53 → D23: the configured permissions decide, which differs from the Q53 recommendation
  (two different people).
* **New open owner question:** Q54 (§19.2), details D22 does not settle.
* **Technical questions:** OT9 fully resolved; OT1 decided by D22 except Q54 (§19.3).

**Revision 16 (owner decisions D24–D27, §2 U):**
* **Resolved:** Q54 (a) → D25, matching the never-silent interim; Q54 (b) → D26 and Q54 (c) → D27, each matching
  the recommendation; D24 clarifies D22's scope (actual employment dates of the final period).
* **New open owner question:** Q55 (§19.2), non-blocking: how a D25 pending case is eventually resolved.

**Revision 17 (owner decisions D28–D32, §2 V):**
* **Decided for R3.1:** last-resort full-payload logging (D28), original-attempt timestamp (D29), operational-only
  business dashboard (D30), dormant first release (D31), escalation badge (D32). No question opened or reopened.
* **R3.1 hardening:** whole delivery-transaction failure recorded as a failed attempt (D33); D28 clarified (log only,
  never an error reporter). **Open, non-blocking:** the retention period for host / container logs that may hold a
  D28 line (a recommended default is configured; `docs/durable_audit_operations.md` §4). **Decided 2026-11-10 (D34):**
  20 MB × 5 Docker log rotation (at most 100 MB per container, effective once containers are recreated); no automatic
  deletion of the database payload in R3.1; the full payload is never sent automatically to an external error reporter.

**Implementation questions** (original text kept for traceability; the ID cell shows each question's status after
revision 16, and only rows marked **Open** still need an owner answer)

| ID | Question | Proposed default **[P]** |
|---|---|---|
| Q3 — resolved: D1 (1), D9 (reference point D10) | The review deadline date (A2) — which is also the transition deadline for Not Reviewed and HR-exception-list employees (L25) — and the date the legacy exception for assignments without a schedule (L9 (1)) ends | Owner to set two dates: HR review complete; schedules defined for all current assignments. Enforcement (phase R5) starts with the first payroll period after the later one. |
| Q4 — resolved: D3 + **[T]** | Holiday Calendar owner and granularity: business-wide only, or per branch? Who manages it (permission)? Holiday worked — any premium? | Owner: Workforce (scheduling calendar) or OA (business settings) — choose one. Business-wide + optional branch rows. Premium pay out of scope. |
| Q5 — decided **[T]** | "Termination date" (C) does not exist in the data | Use the employee's last active assignment end, salary-profile segments and account deactivation as today; or add an explicit employment end date in Workforce (new column) — owner choice. |
| Q6 — decided **[T]** | Mid-period transitions between branch-assigned, floating and central | Keep "last state decides the whole period" (§4.2), consistent with the approved attribution rule. |
| Q7 — decided **[T]** | Which rule version applies to a period | The version in force on the period's last day, consistent with Q6. |
| Q8 — decided **[T]** | Re-finalization after a reopen when a newer version became effective for that period | Re-resolve by date (Q7); new versions may not have an `effective_from` inside any finalized or paid period, so only a version created while the period was open can change the result; the change is audited. |
| Q9 — resolved: D4 | "Locked, finalized, **approved**, or paid" (A5) — no payroll status is called "approved". Does `branch_review_completed` (or `under_review`) count as locked for backdating? | Treat `finalized` and `paid` (`PayrollPeriod#locked?`) as locked; owner to confirm whether `branch_review_completed` also blocks backdating. |
| Q10 — resolved: D5 (a) | Concurrent regular assignments at different branches (allowed today, §3.1) with different weekdays: P9 takes one winner per date and ignores the other's weekdays | Owner to choose: forbid overlapping regular assignments for new assignments (successive only, A8), or make the per-date winner weekday-aware. |
| Q11 — resolved: D5 (b) | Daily rate used to price an absent day for monthly-paid employees (today base ÷ `working_days_per_month`) | A6 governs counting, not pricing. Keep today's price divisor until the owner decides otherwise. |
| Q12 — resolved: D2 | Does the "Allocated Central Staff Costs" aggregate (I) also contain floating employees' allocated costs? | Same aggregate, labelled "Allocated Central & Floating Staff Costs" — owner to confirm the label and grouping. |
| Q13 — decided **[T]** | `manage_cost_allocations`: "business-level" yet "respecting branch scope" | Grant per business (not employee-scoped); branch rows limited to `BranchScope` of the user; a rule containing branches outside the user's scope can be viewed but not versioned by that user. Dependencies: `view_expenses` and `view_employees` (owner to confirm). |
| Q14 — decided **[T]** | Mobile check-in for floating employees (no branch on the assignment, so `assigned_to_branch?` fails) | Out of scope; biometric remains their channel (PR #110). Owner to confirm. |
| Q39 — resolved: D6 | Termination payout amount and payroll treatment (carried from Q34 (h); L31 approves only that payout is configurable): which daily rate prices a paid-out day, whether it is paid through the final payroll entry, and the termination date itself (Q5) | **No approved default.** **[P]** price each day at the leaver's applicable monthly salary ÷ scheduled working days in the final payroll period (the L28 basis), paid as a separate line in the final payroll entry; until decided, a leaver's balance is settled as "pending decision" in the ledger, never silently paid or forfeited. Owner decision required |
| Q40 — resolved: D7 (principle); design R7.0 | Mechanism for L32's per-employee finalization block: finalization is per period today (§3.6), with central review, `Payroll::FinalizationEffects`, insurance expense, allocation snapshots and `pay_payroll` all period-level | **[P]** an entry-level hold (`finalization_hold` with reason and actor) set when an employee is Flagged for Review; the period finalizes with held entries excluded from `period_finalized`'s payload; a held entry is released and finalized later through its own audited step that passes only that entry's costs through the same contract, never reopening the period; held entries cannot be paid. It changes the payroll lifecycle and the contract, so it needs its own approved design before R7. Until approved, R7 must not ship the unpaid-leave deduction. Owner and architecture approval required |
| Q41 — resolved: D8 (c) | Limit on resubmissions after a rejected historical correction (L35) | **[P]** no fixed limit; every resubmission is a new record linked to the request it replaces, so the full chain stays visible and each passes the full approval workflow. **Recommendation awaiting confirmation** |
| Q42 — resolved: D1 ((a), (b)); (c) **[T]** | Identities: (a) L34's **System Administrator** — no platform-level role exists; every user belongs to one business (§3.6); (b) L35's **Super Admin** — the code uses the term for the business owner; (c) how the Business-level responsible person (L34) is designated | **[P]** (a) a new platform-operator identity owned by OA, held outside `PermissionRole` so no business role can grant it, with its own access check (not `require_admin_access!`); until it exists the system-wide dashboard and Retry Now are not available and monitoring stays on `Rails.error.report`; (b) Super Admin = the business owner, so the fallback stays inside the business (L35 "preserve business scope"); (c) an explicit permission (e.g. `monitor_audit_failures`, business scope, never in role defaults). Owner to confirm all three |
| Q43 — decided **[T]** | Default role mapping for L35: no HR or Finance Manager archetype exists (§3.6); the name of HR's separate Finance-Approver management permission | **[P]** no automatic grant to the existing archetypes (`accountant` included); each business grants the two permissions through its own roles; add `hr` / `finance_manager` archetypes only if the owner wants defaults. Permission name e.g. `manage_historical_correction_approvers` (OA, business-level). Owner to confirm |
| Q44 — resolved: D8 (a) | Configurable leave types (L33) vs L6 (daily-paid employees: unpaid leave only): may a configured paid type (e.g. paid sick leave) apply to daily-paid employees? | **[P]** no: L6 stands; a type's paid effect applies to monthly-paid employees only and daily-paid employees see unpaid types only. Changing L6 needs an explicit owner decision |
| Q45 — (d) resolved: D8 (b), which differs from the (d) recommendation here; others **[T]** | Minor leave operations L31 / L33 leave open: (a) "available balance" at approval; (b) proration formula; (c) alignment of accrual periods to the leave year; (d) a carry-over shortly before 31 March expires within days under the literal reading of L31; (e) leave partly in a locked period and partly open; (f) effect of a service-date correction on past accruals and on the first requirement row (L18); (g) the fallback approver chain; (h) who approves a new leave type's activation | **[P]** (a) accrued, unexpired balance minus already-approved untaken paid leave, counting only batches still valid on every requested date; no future accrual counted. (b) entitlement × eligible days ÷ days in that leave year, 2 dp. (c) accrual periods start on the leave-year anniversary. (d) apply literally: the first 31 March strictly after the carry-over date — owner to confirm. (e) the whole request is treated as having affected locked payroll (HR/Payroll Review); no partial cancellation. (f) prospective only: past accrual and requirement rows are never rewritten; any difference is an explicit audited adjustment entry. (g) next level (area manager → HR → business owner), configurable; if the chain is exhausted the request stays pending with a visible warning, never auto-approved. (h) activation by a user with a leave-type permission other than the one who defined it, audited. All recommendations, not decisions |
| Q46 — resolved (rev. 9): (a) D10, (b) D11, (c) D12, which differs from the (c) recommendation, (d) D13, (e) D14 | Points D1–D8 leave open, which this plan interprets until confirmed: (a) D1 (1) "after deployment": deployment of what? (b) D5 (b): does L28's public-holiday denominator setting also apply to the absence denominator? (c) D5 (b): how is absence priced when the period's scheduled working days are incomplete because part of the period is on a legacy assignment without weekdays (L9 (1))? (d) D6: which rate is "the approved daily rate"? (e) D8 (b): which "year" — the calendar year of the carry-over date? | **[P]** (a) the production deployment of R3.3, the backfill that first records Not Reviewed rows; the first complete Payroll Period is the first one that starts after it. (b) Yes: one divisor for absence and unpaid leave (`Payroll::DailyRate`), so a date is never priced two ways. (c) No absence deduction for that employee in that period, a payroll-review warning, and finalization allowed, consistent with L9 (1) and with "never invent a denominator"; not Flagged for Review under L32 unless unpaid leave is also affected. (d) The D5 (b) rate: the applicable monthly salary in force on the employment end date ÷ the scheduled working days in the final payroll period; a missing denominator is Flagged for Review (L32), never invented. (e) The calendar year that contains the carry-over date: a batch carried over in year Y expires on 31 March of Y + 1. **Owner confirmation required.** What each point blocks: (a) only R5's cut-off; (b)–(d) only R7; (e) only R6b's expiry job |
| Q47 — resolved (rev. 10): D15 | How is the D5 (b) / L28 rate (salary ÷ Scheduled Working Days in Payroll Period) applied when only part of the Payroll Period counts? (a) D12: for the reliably scheduled dates of a partly unscheduled period, the period's full Scheduled Working Days are unknown and may not be estimated; counting only the known days raises the price of each day (half the period known → each day costs about twice the full-period rate). (b) Joiners and leavers: the employment window covers only part of the period, so the same question arises for absence and unpaid leave. (c) D13: a leaver's final Payroll Period is usually partial, so the payout rate meets (b); a leaver with few scheduled days in the window would get a much higher rate | **[P]** For (a)–(c): price = the part of the applicable monthly salary attributed to the counted dates (the calendar-day proration `BasicSalaryCalculator` already applies, to be re-verified on the new baseline) ÷ the Scheduled Working Days among those dates. For a fully scheduled, fully employed period this is exactly the D5 (b) formula. No unscheduled day is estimated and no fixed divisor is used. If the counted dates contain no Scheduled Working Day, nothing is deducted for absence (D12), and unpaid leave or a payout is Flagged for Review (L32; D6's never-silent settlement). **Owner decision required.** Blocks only R7 for these cases; fully scheduled, fully employed periods are unaffected |
| Q48 — resolved (rev. 11): D16, which is none of the options below | Unpaid leave for a monthly-paid employee with no schedule at all. Central employees (B) do not require attendance and have no `ShiftAssignment`, so they have no scheduled working days: the D15 / L28 denominator is zero for every date, and L32 would flag every approved unpaid-leave request. How should unpaid leave be priced for them? | **[P]** Until decided, apply L32 as approved: the employee is Flagged for Review, no denominator is invented and no 26 or 30 is used. Options for the owner: (a) keep L32 (every case reviewed by hand); (b) price on a defined working week set for the employee by HR (a new schedule concept); (c) do not offer unpaid leave to employees without a schedule. **Owner decision required.** Blocks only unpaid leave for employees without a schedule in R6b and R7 |
| Q49 — resolved (rev. 12): (a) D17, (b) D18 | Two points D16 leaves open. (a) **Scope:** does D16 cover only employees who have no work schedule by design (not required to attend, such as central employees, B), or also employees who require attendance but whose schedule is missing or unreliable on the leave dates (no assignment, C; a legacy assignment without working days, L9 (1), D12)? (b) **Payout:** the termination payout uses the scheduled-day rate (D6, D13, D15), which is undefined for an employee without a schedule; D16 covers unpaid leave only | **[P]** (a) only employees without a schedule by design; required employees keep C (blocks finalization), D12 and L32 (Flagged for Review), so a missing schedule is never hidden by a calendar-day deduction. (b) until decided, such a payout is Flagged for Review (OT1, D6's never-silent settlement); extending Calendar-day Proration to it needs an explicit owner decision. **Owner decision required.** Blocks only these cases in R7 |
| Q50 — resolved (rev. 13): (a) D19, (b) D20 | Two points D18 leaves open. (a) **Forfeited setting:** L26 / L31 make the termination settlement configurable ("paid" or "forfeited"), and D6 writes a recorded forfeiture entry under "forfeited". D18 says the balance is not forfeited. Does D18's hold also apply when the business's setting is "forfeited" (no rate is needed then)? (b) **Eventual payout calculation:** D18 holds the settlement "until a reliable payout calculation … is available"; no calculation for employees without a schedule is approved | **[P]** (a) Until decided, hold in both cases: a hold is reversible and a forfeiture is not, and D18's wording forbids forfeiture. If the owner confirms that the configured forfeiture applies, the review resolves it as a recorded forfeiture entry. (b) No default; the hold continues until the owner approves a calculation (for example D16's calendar-day basis extended to the payout). **Owner decision required.** Non-blocking for R7: the hold itself is implementable |
| Q51 — resolved (rev. 14): D21 | **Setting version at release.** Leave policies are versioned by `effective_from` (§8), and a held settlement may stay pending for a long time. D19 says the business's configured termination policy is applied once the hold is released. If the business changes its setting between the employment end date and the release (for example from `Forfeit` to `Pay Out`, or the reverse), which applies: the setting in force on the employment end date, or the one in force on the release date? | **[P]** The setting in force on the employment end date: the held amount is already fixed at that date (§18.10.2 K52), the payout profile is the end date's (§18.7.2 K21), and a later setting change then cannot alter a held case retroactively in either direction. **Owner decision required.** Non-blocking: no settlement is released before D20 (1) |
| Q52 — resolved (rev. 15): D22, in the direction of the recommendation below (its salary-profile part and the sub-cases: Q54, decided in revision 16 as D24–D27) | **Payout for a required leaver without a scheduled day** (former OT1): how is the termination payout priced when an employee who requires attendance leaves and the final Payroll Period has no reliable scheduled working day inside the employment window? D13 / D15 give a zero denominator; D16 / D17 forbid Calendar-day Proration for required employees; D18–D21 cover only not-required employees | **[P]** The D15 rate of the most recent Payroll Period of the employment with at least one reliable scheduled working day, at the profile in force on the employment end date (K21). Interim: payout line not created, settlement case listed for review, balance never paid, forfeited or zeroed (§19.2). **Owner decision required.** Blocks R7 for that case only |
| Q53 — resolved (rev. 15): D23, which differs from the recommendation below | **Same person for D20 (2) and (3)** (from OT9): may one person record both the HR review and the Payroll approval of a held settlement (for example an owner, or a user with both permissions)? | **[P]** No: two different people, by identity through `Approvals::SelfApproval`, no owner exception, no opt-in. Interim: two people required (§19.2). **Owner decision required.** Blocks only the release, which also waits for D20 (1) |
| Q54 — resolved (rev. 16): (a) D25, (b) D26, (c) D27, each matching the recommendation below; scope D24 | **Details D22 does not settle** (termination payout of a leaver who is required to attend and has no scheduled working day in the final Payroll Period): (a) **No reference period:** what applies when no preceding Payroll Period has scheduled working days for the employee (for example, employment started and ended inside the final period, or the employee was never scheduled)? (b) **Salary in the reference rate:** is the rate the reference period's own D15 rate (the salary profiles in force on its dates), or the reference period's eligible dates and scheduled working days applied to the salary profile in force on the employment end date (K21)? The two differ when the salary changed after the reference period. (c) **"Reliable" period:** must the reference period be reliably scheduled throughout, or does a period with at least one reliable scheduled working day qualify, the rate then using only its reliable dates (D12, D15)? | **[P]** (a) No rate proposed: any basis would be a new pricing rule. Until decided, the never-silent handling stays: no payout line, a settlement case listed for HR/Payroll review, the balance never paid, forfeited or zeroed (D6). (b) The profile in force on the employment end date, consistent with K21 and D13. (c) At least one reliable scheduled working day, priced over the reliable dates only (D12, D15). **Owner decision required.** (a) blocks R7 for that case only; (b) and (c) block R7's D22 payout code only |
| Q55 — **Open** (rev. 16) | **Resolution of a D25 pending settlement.** D25 keeps the termination leave settlement of a leaver who is required to attend and has no reference period pending HR/Payroll review, but does not say how such a case is eventually resolved: whether review steps like D20 (2) and (3) apply, and on which payout basis, since no D22 rate can be calculated | **[P]** No basis proposed: any rate would be a new pricing rule. Until decided, the case stays pending and listed for HR/Payroll review; nothing is paid, forfeited, zeroed or discarded (D25). **Owner decision required.** Non-blocking: R7 builds the pending case; only its resolution waits |

---

## 6. Target behaviour and lifecycle diagrams **[P]**

### 6.1 Attendance requirement lifecycle (Workforce)

```
   new employee ──▶ HR must select REQUIRED or NOT REQUIRED on creation (mandatory, no default);
                    first row effective from the employment start date (L10, L18)

   existing employee ──▶ backfill row for everyone (L11), dated per L12:
                           daily-paid → REQUIRED · everyone else → NOT REVIEWED (explicit value)
                           no reliable date → HR EXCEPTION LIST, no row until HR review (L19, L25)

              NOT REVIEWED ──────────────── legacy eligibility (A2); never silently "not required" (L4, L11);
              │         │                   no new daily salary profile (L13)
     HR sets  │         │ HR sets
     required │         │ not required
              ▼         ▼
          REQUIRED ◀──▶ NOT REQUIRED
            (effective-dated rows in employee_attendance_requirements, append-only;
             HR never sets NOT REVIEWED — it is written only by the backfill)

Change service (the one WF writer of history rows and the cache; one transaction):
  1. authorise: manage_employees within the employee's management scope (UserPolicy#update? scope)
  2. acquire the per-employee advisory transaction lock (L3, §6.6) — first lock of the transaction
  3. validate:
     • to "not required": no assignment active on or after effective_from (open-ended ones must end
       before it; future ones ended or cancelled)                                  (A5)
     • effective_from < today (business day) → reason required, and no payroll period Under Review or later
       (under_review, branch_review_completed, finalized, paid)
       touches [effective_from, today)                                             (A5, D4)
     • to "required" for a floating or central transition: nothing extra
  4. append history row (value, effective_from, actor, reason)
  5. invariant check over the whole resulting timeline through the WF-defined contract,
     implemented by AP: any daily-paid date now not required → reject (L1, L2, §6.6)
  6. update users.requires_attendance cache to the value in force today (or leave for a
     roll-forward when effective_from is in the future — see 6.2)                  (A3, L4)
  7. log_audit(old, new, effective_from, reason)
  on any rejection: roll back (no history row, no cache change), then record the rejected
  attempt in a separate transaction (L8, L14, §6.6) and return a failed Result with the reason

Employee creation (admin form, data-request approval): the user row and the first history row
are written in ONE transaction through the same service; a missing selection or start date
rejects the creation (L10, L18). The new employee has no salary profile yet, so the invariant
is enforced when the salary profile is created (direction 1, L2).
```

### 6.2 Effective dates and future changes

* The requirement in force on date *d* = the latest history row with `effective_from ≤ d`: required, not required
  or **not reviewed** (an explicit backfill value, L11). No row on *d* — dates before an employee's first row, or an
  HR-exception-list employee (L12 (3)) — is treated as not reviewed (L25); it is never "not required".
* For the invariant only **required** satisfies a daily-paid date; not reviewed and no row do not (L13).
* A future-dated change is accepted only when no assignment is active on or after its date (A5). From then on, the
  `ShiftAssignment` validation (6.3) refuses any assignment overlapping dates where the requirement is "not
  required".
* **[P]** The cache reflects "today": a future-dated row updates the cache when it takes effect, through a small
  daily Workforce job (registered in `config/recurring.yml`) or by deriving on read; the history row is always the
  truth (A3).

### 6.3 Assignment enforcement (Workforce, every path)

```
ShiftAssignment validation (create and update; every path ends here)
  for the assignment's date range:
    requirement "not required" on any date in range → error (A4)
    "not reviewed" → legacy rules (A2)
  new assignment → working_weekdays present, 1..7 values in 0..6; absent → rejected (A7, L9 (3))
  existing (legacy) assignment with NULL working_weekdays → stays valid (L9 (1)); the exception
    never applies to a new assignment
  new regular assignment overlapping a regular assignment of the same employee at a different
    branch → error (D5 (a)); other-branch work uses temporary coverage or a floating assignment;
    existing overlaps stay valid and are reported, never reinterpreted
  existing validations unchanged (overlap, floating exclusivity, active branch, same business)

Callers surface the error in their own shape:
  UI form errors · bulk result row "skipped: reason" · API error JSON · template RowError · coverage form errors
```

### 6.4 Scheduled day and absence (Attendance & Payroll)

```
for each date d in [payroll range] ∩ [employment window] :
  req    = requirement on d                           (WF read; not required → no absence, no lateness)
  winner = AssignmentResolver winner on d             (coverage > latest effective_from > id; P9)
  if no winner and req ∈ {required}        → finalization blocker C (missing assignment), no deduction
  if winner.working_weekdays IS NULL       → legacy undefined day: no deduction, payroll-review
                                             warning, finalization still allowed (A7, L9 (1), D12)
                                             until the D9 deadline; after it, blocker C (L9 (2))
  scheduled = d.wday ∈ winner.working_weekdays AND d not a Holiday Calendar date (A10)
  on_leave  = APPROVED leave covers d — WF leave data read by AP;        (L6, L15)
              pending / rejected / cancelled leave has no effect
  absent    = scheduled AND d elapsed AND NOT on_leave AND no complete attendance on d
eligible dates E = payroll range ∩ employment window ∩ reliably scheduled dates     (D12, D15)
daily_rate(d) = salary attributable to E at the profile in force on d                (D15)
                  ÷ scheduled_working_days(E)
                split at salary-profile boundaries; numerator and denominator cover the same E;
                E = the whole period for a fully eligible employee → exactly D5 (b) / L28
                (segment handling and the attribution basis: OT2, OT3)
deduction  = Σ over absent days d in E: daily_rate(d)                                (D5 (b), D15)
             same basis as L28; never 26; monthly-paid part only; Parity Report before rollout
             denominator: approved public holidays excluded per the L28 setting (D11)
             partly unscheduled period: unscheduled dates neither deducted nor estimated; the
               reliably scheduled dates calculated normally (D12); their price per D15
             a date is either absent or on approved leave, never both → never deducted twice
daily-paid: pay = rate × approved complete attendance days (today's rule); assignment + schedule required (A9, C)
            approved unpaid leave day → not absent, not a paid day, no deduction (L6)
other configured leave types → the balance, attendance and payroll effect the type defines (L33);
            an inactive type, or one without all three effects, cannot be requested
monthly-paid: approved PAID annual leave day → not absent, salary not reduced (the leave balance
              is reduced in WF at approval, FEFO, never below zero — L16, L26, L31)
              approved UNPAID leave day → not absent; deduction (L23, L28, D15) =
                Σ over unpaid_leave_workdays d in E: daily_rate(d)   (the same rate as absence)
                applicable salary = profile in force on each unpaid-leave date (split at
                  effective-date boundaries, as BasicSalaryCalculator segments salary)
                denominator = the employee's reliable scheduled working days over E — the whole
                  payroll period when fully eligible (not the calendar month); weekly rest days
                  excluded; approved public holidays excluded only if the business setting says
                  so (D11); never a fixed 30 or 26
                no work schedule (e.g. a central employee) → Calendar-day Proration (D16), a
                  separate formula, never the scheduled-day rate and never a fabricated schedule;
                  formula details OT4–OT8; only when the requirement in force on d is not
                  required (D17); a required employee with a missing or unreliable schedule
                  never uses D16: C, D12, L32 as before
              schedule or denominator missing / invalid → payroll-review flag, no invented
                denominator (L23, L28); no unreliable deduction is calculated; the employee is
                Flagged for Review and finalization is blocked for that employee only (L32;
                principle D7, mechanism R7.0)
approved after the period is locked → kept with real dates and approval timestamp, flagged for
              HR/Payroll review, locked payroll untouched (L21)
cancellation (L27, L33) → only while the leave has not affected locked payroll; the request alone
              cancels nothing; once approved at the original level, open periods recalculate
              after commit; requested after the leave affected locked payroll → leave and payroll
              history unchanged, HR/Payroll Review case, separate audited correction
```

**Two prorations stay distinct [A]:** scheduled-day proration (D5 (b), L28, D15) prices absence and unpaid leave
for employees with a reliable schedule; Calendar-day Proration (D16) prices unpaid leave only, for monthly-paid
employees who do not require attendance (D17). An employee who requires attendance but lacks a reliable schedule is
never priced by D16; the warnings, C, D12 and L32 apply to them as before. Absence never uses D16: an employee without a schedule has no scheduled days and
so no absence.

Three concepts stay separate (L6, L16): **attendance classification** (scheduled / attended / absent / on leave —
this algorithm, AP), **leave approval and entitlement** (type, dates, status, paid or unpaid, balance — Workforce,
L15), and **payroll treatment** (pay, unpaid-leave reductions and absence deductions — `EntryCalculator`, AP). Leave
never changes `requires_attendance` or `salary_type`. The entitlement policy is L22 with the balance rules of L26
(§6.7); approval and cancellation L27; leave approved after a payroll lock: L21. **[A]** The holiday-exclusion setting
affects both the L28 and the D5 (b) denominators (D11); a Holiday Calendar date is never an absence (A10) whatever
the setting. **[T]** The setting covers approved public holidays only, so company holidays stay in the denominator
(§18.7.2 K20).

Rotation (A8) is a chain of successive assignments; partial months fall out of the date intersection; new hires
and leavers are bounded by the employment window (Q5).

### 6.5 Payroll finalization with allocation (Payroll ↔ Finance through the contract)

```
Payroll::Approver#advance (inside the existing transaction, period row locked)
  existing refusals (central review, pending adjustments, recalculation review)
  NEW  attendance-data blockers (AP-only): required employees with no applicable assignment and working
       schedule in the active employment period (C, L9 (2)); legacy assignments without weekdays
       warn only and do not block (L9 (1), D12) until the D9 deadline; after it they block (C)
  NEW  costs = per-employee payload built by Payroll:
         { user_id, attribution: :branch(branch_id) | :floating | :central,
           gross_salary, employer_insurance }
  NEW  blockers = FinalizationEffects.allocation_blockers(period:, costs:)   ── Finance implements
       any → refuse finalization with the list
  D7   employees Flagged for Review (L32) are held, not finalized; the others continue and are paid
       on time; a held entry is finalized and paid later in the same period, its cost Provisional
       until released — mechanism designed and approved in R7.0 (§18.6.3), not here
  FinalizationEffects.period_finalized(period:, actor:, costs:)               ── Finance implements
       Finance: resolve rule versions → MoneySplitter → snapshot rows →
                one fully allocated employer-insurance Expense (no unallocated part)
Payroll::Reopener → FinalizationEffects.period_reopened(...) → Finance voids expense AND snapshot rows
```

### 6.6 Daily-paid attendance invariant — both directions (L1–L8)

**Invariant [A]:** for every date *d* of the employee's whole timeline (past, present, future):
*salary type in force on d is daily ⇒ requirement in force on d is required.*

**Contract and read API [P]** (names provisional; shapes follow `Shifts::AttendanceUsage` / `Employee::ProfilePanels`):

| Piece | Owner | Shape |
|---|---|---|
| Requirement read API, e.g. `Employee::AttendanceRequirements` | WF | `timeline(user_id:)` / `not_required_ranges(user_id:, from:, through:)` over the history rows (never the cache); read-only |
| Lock helper, e.g. `Employee::AttendanceRequirements.lock_employee!(user_id:)` | WF | `pg_advisory_xact_lock(<namespace>, user_id)`; must be called inside a transaction |
| Check contract, e.g. `Employee::AttendanceRequirementChecks` | WF defines | one operation in Workforce terms — e.g. `first_conflict(user_id:, not_required_ranges:)` → nil or `Conflict(date:, reason_key:)`: "the first date on which a downstream rule needs this employee to require attendance". It names no AP concept; `reason_key` is an i18n key owned by the implementer (as `ProfilePanels` returns an AP-owned partial path) |
| Contract implementation, e.g. `Payroll::DailyPaidAttendanceCheck` | AP implements | answers from `SalaryProfile` periods in force (daily); registered in its own initializer (`config/initializers/…`, `to_prepare`) |

Dependencies: WF → its own contract only; AP → WF read API, lock helper and contract (allowed AP → WF). No WF → AP
reference, no cycle. A boundary spec enforces it (§15).

```
Direction 2 — requirement change (WF change service, §6.1)
  BEGIN
    lock_employee!(user)                         (L3 — first lock in the transaction)
    validate A5 rules; append history row
    ranges = not-required ranges of the WHOLE resulting timeline
    conflict = AttendanceRequirementChecks.first_conflict(user, ranges)   ── AP implements
    conflict → ROLLBACK (no row, no cache change) → record rejected attempt → failed Result
    else cache + log_audit → COMMIT
  payroll recalculation, if any: after commit

Direction 1 — salary profile create or correct (Salary::ProfileUpdater / ProfileCorrector)
  BEGIN
    lock_employee!(user)                         (L3 — same lock, same position)
    existing writes (deactivate + create!, or assign + save!) — unchanged behaviour
    daily ranges = periods in force of every daily profile, after the write (whole timeline,
                   future-dated profiles included; a moved effective_from re-sizes the
                   neighbouring profiles' periods, so the check re-reads the result)
    conflict = any daily date whose requirement (WF read API) is not "required" —
               not required, NOT REVIEWED or no row all conflict           (L2, L13, L25)
    conflict → ROLLBACK (no profile written or changed) → record rejected attempt → failed Result
    else log_audit → COMMIT
  recalculate_open_periods: after commit, unchanged (L3)
```

* **Whole-timeline check after the write [P]:** both sides re-validate the complete resulting timeline instead of
  reasoning about which interval changed; one employee has few rows, so this is one or two queries. It covers in-place
  `salary_type` changes, moved `effective_from` dates and future-dated rows on either side (L2).
* **Lock order [A]/[P]:** the per-employee invariant lock is the first lock in both transactions; neither service
  takes payroll period or entry locks inside that transaction (recalculation runs after commit), so the documented
  request → period → entry order is unaffected. It is a different namespace from the floating plan's
  employee-and-business-month salary-advance lock (its §8.9); if a future flow ever needs both, the invariant lock is
  taken first. Every salary-profile create or correction takes the lock, including monthly ones (a monthly
  correction can lengthen a preceding daily profile's period).
* **Reject only [A]:** neither service changes the other side to resolve a conflict (L2). Daily → Monthly conversion
  is an ordinary new monthly profile and leaves the requirement unchanged (L7).
* **Errors [P]:** WF returns `Result.new(ok: false, error: :daily_paid_requires_attendance, …)` with the conflicting
  date; the salary services keep their existing `Result(success:, profile:, errors:)` shape with the error on
  `profile.errors[:salary_type]` so the admin form and the API `render_error` work unchanged. EN + AR messages
  name the conflicting date.
* **Rejected-attempt audit [A] (L8, L14), mechanism [P]:** a `log_audit` entry written inside the transaction that
  is then rolled back disappears with it (§3.6). Approved order (L14): roll back the main transaction (releasing the
  lock, leaving no profile or requirement row), then write the rejected-attempt entry in a **separate transaction**.
  Proposed entry: auditable = the target employee; action e.g. `daily_paid_attendance_rejected`; metadata: attempted
  operation, current and requested values, conflicting date and reason, source (admin / api / backfill); actor and
  timestamp from the audit row. Called outside any transaction, today's `log_audit` write already runs as its own
  transaction (§3.6), but its failure handling (report and return nil) is **not enough**: L14 requires that an
  audit-write failure is never silently swallowed. L20: the event is kept in a **durable operational record** until
  Audit Log persistence succeeds, a **background job** retries the write, and **system administrators are alerted**
  if failures continue — through the administration notifications dashboard, with failure status and retry
  information (L29, L34). **[P]** order: (1) roll back the main transaction; (2) in a new
  transaction write the Audit Log entry; (3) if that fails, in another new transaction write the durable record
  (the source of truth) and enqueue the retry job after commit. *(Revision 7 correction: the earlier wording that both
  "commit or neither" is wrong in production, where Solid Queue writes through its own `queue` connection —
  `config/environments/production.rb:53`. A lost enqueue is harmless because a recurring sweeper re-enqueues due
  records, §18.2 G10.)* (4) the job
  writes the Audit Log entry and marks the record delivered in one transaction, idempotently (the record's id is
  carried into the entry, so a retry never writes twice); (5) if the durable record itself cannot be written, the
  full payload goes to `Rails.error.report` and a structured log line as the last-resort recovery source (D28: this
  fallback only; the global audit-failure reporting is unchanged — *revision 17 hardening: the log line only, never
  the error reporter, §2 V D28 clarification; idempotency is the receipt of §19.13 T-R31-11, not an id in the
  entry*); (6) after
  3 consecutive failed attempts the event is escalated on the dashboards; its one notification is updated in place
  and marked Resolved on delivery, never deleted (L34, §6.8). The durable record, not the notification, remains the
  recovery source (L29). The user
  still receives the rejection; nothing about the rejected change is persisted. Design requirement, not an existing
  capability; verified in implementation (R3).
* **Historical Violations [A] (L5, L17):** the check covers the whole history, but a rejection never reopens,
  recalculates or modifies a locked, finalized or paid period. A conflict that already exists in history (for
  example found by the post-backfill check) is recorded as a **Historical Violation**, shown on the HR/Payroll review
  report, and corrected only through a separate audited, authorised and approved process; no amount is redistributed
  or altered automatically. Review (L24): HR reviews the employee and attendance facts, Payroll the financial impact;
  a correction needs permission and documented approval; a violation is never deleted, only closed by an audited
  corrective action with a reason (storage [P] §8). Permissions (L30): HR review `manage_employees`, Payroll review
  `view_payroll`, executing a correction `manage_historical_payroll_corrections`, approving it
  `approve_historical_payroll_corrections` — separate permissions, so execution and approval are separated.
  Correction workflow, Finance Approvers and Super Admin fallback: L35, §6.9. The backfill's date and evidence rules (L12,
  L19) are designed to create none; employees with missing or conflicting evidence go to the HR exception list
  instead (L25).
* **What the invariant does not mean (L5):** a required date is not a "must punch" date; rest days, holidays and
  approved leave follow §6.4.

### 6.7 Leave entitlement, types, approval and cancellation (Workforce; L22, L26, L27, L31, L33)

**Approved rules [A]** (L26, L31, L33): an individual leave year from the anniversary of the HR-approved Employment
Start Date; tiers 15 / 21 / 30 days per year (first year / from the second year / after 10 full years), configurable
per business, with a configurable accrual frequency; proration by eligible service when employment starts or ends
mid-year; a tier change inside a leave year splits accrual at the qualification date, earlier accruals never
recalculated; two-decimal balances, never rounded in storage; no negative balance; carry-over of at most 5 days
(configurable) in separately kept batches, each expiring on 31 March following the year in which it was carried over (D8 (b); carried over in 2026 →
expires 31 March 2027, D14), the excess forfeited;
FEFO consumption; accrual continues during unpaid leave; termination settlement configurable per business
(`Pay Out` / `Forfeit`, D19), history kept. Leave types
configurable, each with defined effects and inactive until approved; routing by position with a valid fallback, never
auto-approved; no self-approval; cancellation only before locked payroll is affected, approved at the original level.

```
Leave balance = Σ of an append-only ledger, decimal(6,2) — never a writable balance column   [P]
  accrual        +   per accrual period of the employee's leave year (anniversary-based, Q45 (c)),
                     at the tier rate in force; a period containing the qualification date is split
                     at that date — old rate before, new rate after (L31); continues during unpaid
                     leave (L31); first and last leave years prorated by eligible service (Q45 (b))
  usage          −   on approval of paid annual leave, consuming FEFO: carry-over batch closest to
                     expiry first, then the current entitlement; each usage entry names the batch
                     (source, expiry) it consumed (L31); refused if the available balance (Q45 (a))
                     is insufficient — the employee may request unpaid leave instead
  cancellation   +   compensating entries restoring exactly the consumed batches (L33)
  carry-over         at the leave-year anniversary: up to the cap (5, configurable) becomes a new
                     batch {source leave year, amount, expires_on = 31 March of the year after the
                     carry-over year (D8 (b), D14)}; the excess → forfeiture entry (−)   (L26, L31)
  expiry         −   each batch's unused remainder on its own expiry date
  settlement         on termination, per the business setting: payout (D6: remaining eligible days × the D5 (b) daily rate over the
                     eligible dates of the final period, D13, D15) or forfeiture;
                     recorded either way (L26, L31)
                     employee not required to attend, no schedule at the end → HELD (D18),
                     under either setting (D19): no settlement entry yet; a pending HR/Payroll
                     review case records the balance in days as of the employment end date;
                     never paid automatically, never forfeited, erased or zeroed while pending;
                     released only after D20 (1) a formally approved payout calculation,
                     (2) HR review, (3) Payroll approval of the amount; then (4) the configured
                     setting is applied: Pay Out → one settlement entry, Forfeit → one recorded
                     forfeiture entry; Forfeit never converted into Pay Out (D19);
                     policy = the D21 snapshot at the end date; steps OT9 (§19.3), by the
                     configured permissions, one person or two (D23)
                     setting paid, employee required to attend, no scheduled working day in the
                     final period → payout at the rate of the D22 reference period (the last
                     preceding reliable Payroll Period with scheduled working days), recorded
                     with the line; never Calendar-day Proration (D17); only the employment
                     dates of the final period count (D24); rate = end-date salary (D26) over
                     the reliably scheduled dates of the reference period (D27); no reference
                     period → pending HR/Payroll review, never paid, forfeited or zeroed (D25)
  never: negative balance, rounding of stored amounts, editing or deleting entries, recalculating
         earlier accruals (a service-date correction applies prospectively, Q45 (f))

Leave type (WF, per business)                                                              [P]
  draft ──▶ effects defined: balance (none / own balance / annual), attendance classification,
            payroll (paid / unpaid / other defined rule) ──▶ approved and activated (Q45 (h))
  daily-paid employees: unpaid types only (L6, D8 (a))

Leave request (WF)
  submitted ──▶ routed approver (L27, L33):
                   branch employee  → Branch Manager            (Branch#branch_manager_id)
                   Branch Manager   → Area Manager or HR, per business setting
                   central employee → HR or the business-designated approver
                   requester = routed approver, or approver missing / inactive → fallback or higher
                   level (Q45 (g)); never self-approved (Approvals::SelfApproval); no valid
                   approver → stays pending with a visible warning, never auto-approved
  approved ──▶ visible to AP (attendance and payroll effect); usage entries for paid leave
  rejected / pending ──▶ no effect
  approved ──▶ cancellation requested (leave unchanged meanwhile) ──▶
                 not yet in locked payroll → approved at the original level → cancelled:
                   compensating entries; open periods recalculated after commit
                 already affected locked payroll (fully or partly, Q45 (e)) → no cancellation;
                   leave and payroll history unchanged; HR/Payroll Review case (L21, L33)

Service date (WF): the HR-approved Employment Start Date (users.hire_date, [P]); changed only by a
  WF correction service — permission, mandatory reason, audit {old, new, actor, timestamp}; removed
  from the mass-assigned EMPLOYMENT_ATTRIBUTES (§3.6); never changed by a branch or job change (L31)
```

Every transition, ledger entry, leave-type activation and setting change is audited (`log_audit`); the request
keeps its approval and cancellation timestamps (L21). The termination payout is valued by D6 (daily rate D13 over the eligible dates of the final period, D15; OT3; no scheduled working day in the final period of a required employee: the D22 reference period) and paid by AP as a separate
Final Payroll line (R7). A held settlement (D18) is released only under D20; under `Pay Out` its amount uses the
calculation approved under D20 (1), never an assumed D13 rate. **[T]** The carry-over's calendar year (D14) is the year of its effective date, the
leave-year anniversary, in the business's time zone (`BusinessDay`), never the server date.

### 6.8 Audit-failure notifications and recovery (infrastructure; L20, L29, L34)

**Approved rules [A]** (L34): explicit responsibility (System Administrator system-wide; a designated Business-level
person for their business); escalation after 3 consecutive failed attempts; retries until success; one notification
per failed event, updated in place; Resolved, never deleted; System-Administrator-only Retry Now, no concurrent
retries; tenant isolation in data and queries.

**Tenant-isolation design [P]** — UI filtering is never the control:

* The durable record (`pending_audit_events`, §8) carries `business_id` NOT NULL (every rejected invariant attempt
  targets an employee of one business). The event **is** the notification: one row per failed audit event, so
  de-duplication is structural; its `attempts`, `last_error`, `last_attempt_at`, `escalated_at`, `resolved_at` are
  updated in place. Each attempt is also appended to an attempt log (§8), so history is never overwritten.
* The legacy `notifications` table is **not** used: it is per user, has no `business_id`, and is classified Legacy /
  unused (§3.6). Reusing it would need `business_id`, a change of its module-boundaries status and one row per
  recipient, which breaks one-notification-per-event. Revision 5's **[P]** to reuse it is withdrawn.
* Business-level dashboard: every query goes through a Pundit `policy_scope` that filters `business_id =
  current_user.business_id` at the database level; record lookups are `policy_scope(...).find(id)`, so another
  business's id returns not-found. Access needs the explicit responsible-person permission (Q42 (c)); owners see their
  own business implicitly. A request spec proves cross-business ids are refused.
* System-wide dashboard: only the platform-operator identity (D1 (2), design §18.2 G1) reaches the unscoped query, through its own
  controller and access check — never `require_admin_access!`, which ordinary permissions pass (§3.6). Until that
  identity exists the system-wide dashboard and Retry Now are not built.

```
attempt (automatic job or Retry Now)
  BEGIN; lock the event row (SELECT … FOR UPDATE NOWAIT); resolved? → stop
    another attempt holds the lock → Retry Now refused "retry in progress"; the job skips
  write the Audit Log entry (idempotent through audit_log_id)
  success → resolved_at, audit_log_id; status Resolved (kept, never deleted)
  failure → attempts += 1, consecutive_failures += 1, last_error, last_attempt_at,
            next_attempt_at; consecutive_failures ≥ 3 → escalated_at (first time only)
  append attempt-log row {kind: automatic | manual, actor (System Administrator for manual),
                          started_at, finished_at, result, error}
  COMMIT                                        automatic retries keep running after escalation
```

### 6.9 Historical payroll corrections (Attendance & Payroll; L17, L24, L30, L35)

**Approved rules [A]** (L35) are listed in §2; this is the proposed shape **[P]**. The compensating-entry mechanics
of the financial effect stay out of scope (§17).

```
prepared by HR (manage_historical_payroll_corrections) ──▶ PENDING APPROVAL  (no expiry)
   │  addressed to the business's Finance Approver pool, not to one person
   ├─ approve (approve_historical_payroll_corrections AND a designated Finance Approver)
   │     BEGIN; business approver-pool advisory lock; correction row FOR UPDATE;
   │     re-check: still Pending Approval; approver ≠ preparer unless the business's opt-in
   │     exception is on (Approvals::SelfApproval); approver still designated
   │     → APPROVED {approver_id, approved_at}; COMMIT   — a second approval finds it no longer
   │       pending and is refused (never approved twice)
   ├─ Super Admin fallback (business owner, D1 (3)): same transaction; allowed only if the pool
   │     is empty under the pool lock; mandatory fallback reason; recorded as approver with
   │     approved_via = super_admin_fallback; never while a Finance Approver exists
   └─ reject (any eligible approver): mandatory reason → REJECTED {rejecter, timestamp, reason};
         kept permanently; no financial effect
REJECTED ──▶ HR may resubmit: a NEW request {resubmission_of_id → rejected one, updated
             justification and data}; the rejected request is unchanged; full workflow again;
             no maximum (D8 (c))
APPROVED ──▶ financial effect only now, through the separate audited correction process (§17)

Finance Approver designations (HR, separate permission — Q43 name):
  add / remove under the same business approver-pool lock; each change audited; removal never
  deletes, cancels or rewrites pending corrections or past approvals; pending ones stay with the
  remaining pool, or with Super Admin when the pool is empty — even when HR removes the last one
Lock order: business approver-pool lock → correction row (both short; no payroll period or entry
  locks inside this transaction; the later financial posting follows its own lock order)
```

* **Owner implicit permissions [P]:** an owner holds both permissions implicitly (§3.6). The service therefore
  enforces the L35 rules by identity, not by permission: an owner approves as a Finance Approver only when
  designated, otherwise only through the Super Admin fallback; executor ≠ approver applies to owners too unless the
  opt-in exception is on.
* **Scope [P]:** both permissions business-level (not in `SCOPABLE_PERMISSIONS` or `BRANCH_SCOPABLE_PERMISSIONS`);
  records loaded inside `actor.business`; viewing the amounts still requires `Finance::PayrollCostAccess` and
  `view_payroll`.

---

## 7. Domain ownership and allowed dependencies

Verified against `docs/architecture/module-boundaries.md` §2, §3.2, §3.3, §12.1. "Scheduling" and "Attendance" are
internal areas of Workforce and Attendance & Payroll respectively — no new domains.

| Concern | Owner | Mechanism |
|---|---|---|
| `employee_attendance_requirements`, change service, `users.requires_attendance` cache (WF-stewarded column, §3.2) | WF | — |
| `ShiftAssignment` validation, `working_weekdays`, eligibility, templates, coverage, API assigner | WF | — |
| Holiday Calendar (one business-wide calendar, D3) | WF **[T]** (§18.1 Q4) | AP reads it (allowed AP → WF) |
| Scheduled days, absence, lateness, attendance-data blockers | AP | reads WF (allowed) |
| Daily-paid invariant (A9) — the business rule | AP | **L1** approved |
| Check at requirement change (direction 2) | WF asks, AP answers | **L1** — WF-defined check contract, AP implements (§6.6) |
| Check at salary-profile create / correct (direction 1) | AP | reads the WF requirement read API (allowed AP → WF) |
| Per-employee invariant lock | WF (helper) | WF and AP both call it (L3) |
| Leave management: requests, types, approval workflow, dates and status, entitlement records and balances | WF (**L15**) | — |
| Leave policy settings: tiers, accrual frequency, carry-over cap, termination-settlement choice, approval routing and fallback, leave types and their effects | WF (L22, L26, L27, L31, L33) | business-level settings owned by WF; approvers resolved from OA branch data (`Branch#branch_manager_id` / `#area_manager_id`, allowed WF → OA reads) |
| Unpaid-leave (L28, D16) and absence (D5 (b)) deductions and their shared public-holiday denominator setting (D11; not used by D16's calendar-day basis unless OT4 decides otherwise with owner approval) | AP | **[P]** one AP-owned payroll setting per business; reads WF schedules, approved leave and the Holiday Calendar (WF) |
| Settlement of unused leave on termination | WF records the balance and settlement history (L26, L31); AP pays any payout through payroll | AP reads the WF settlement entry; valued per D6 at the D13 rate over the eligible dates of D15 and paid as a separate Final Payroll line; held as a pending review case for an employee without attendance requirement and schedule (D18) under either setting, released only under D20, then the business setting applied (D19); steps OT9 |
| Audit-failure notifications, both dashboards, Retry Now (L29, L34) | **[P]** infrastructure, next to `AuditLoggable` and the durable record (module-boundaries §16); the legacy `notifications` table stays untouched (§6.8) | written only by the retry path; Business-level dashboard scoped by `business_id` in queries; system-wide view only for the platform-operator identity (D1) |
| Platform-operator (System Administrator) identity | OA, outside `PermissionRole` — meaning set by D1 (the WorkPulse platform operations team), design **[T]** G1 | a new cross-business access path: an architecture decision (module-boundaries §18 tenancy rules) approved before R3.5 |
| Service-date correction (L31) | WF | the WF correction service is the only writer of the Employment Start Date |
| Historical payroll correction requests, approvals, rejections, resubmissions (L35) | AP | reads OA permissions and WF employee data (allowed); financial posting through the separate correction process |
| Finance Approver designations and the opt-in same-person exception (L35) | **[P]** OA (business-level authorisation data, next to `PermissionRole`) | AP's correction service reads them (allowed AP → OA) |
| `manage_historical_payroll_corrections`, `approve_historical_payroll_corrections`, the Finance-Approver management permission (Q43) | OA (`PermissionRole`) | checked by the AP correction service (L30, L35) |
| Effect of approved leave on attendance classification and payroll | AP (**L15**) | reads approved WF leave data (allowed AP → WF); never pending leave |
| Leave in Finance | none (**L15**) | Finance owns no leave workflow or approval |
| Historical Violations: detection, records, HR/Payroll review report | AP owns the invariant (L1, L17); HR and Payroll review roles (L24); storage [P] §8 | detection reads WF history (allowed); the report is read-only |
| Payroll figures, finalization lifecycle, per-employee cost payload | AP | — |
| Allocation rules, versions, employee rule links, snapshots, insurance expense, readiness | FS | implements AP-defined `Payroll::FinalizationEffects` (K) |
| Reports (`ExpenseSources`, `BranchProfitability`, `ExpenseDetails`, dashboards) | Reporting | read-only reads of FS snapshots and AP entries |
| `manage_cost_allocations` | OA | `PermissionRole` |

```
        Organization & Access ─────────── permissions (G), branches, accounts
                 │
                 ▼
             Workforce ──── requirement history · assignments · schedules · leave + balances (L15, L26, L27) · holidays (D3)
                 │   ▲
                 │   └── L1: WF-defined requirement check contract, AP implements (approved);
                 │       AP also calls the WF read API and the WF invariant lock helper
                 ▼
        Attendance & Payroll ── absence · approved-leave effect · payroll · daily-paid invariant ·
                 │              Historical Violations · defines Payroll::FinalizationEffects (K)
                 │
                 ▼  (contract, implemented downstream)
          Finance & Sales ── allocation rules · readiness · snapshots · insurance expense

        Reporting ── reads all (read-only); Provisional (live) vs Finalized (snapshot)
```

No upward dependency: Payroll only calls a contract it defines; Finance reads the payload it is given and its own
tables. Workforce only calls the check contract it defines (L1); its code names no AP constant, table or concept.

---

## 8. Data model and additive migration strategy **[P]**

All migrations are additive; nothing is dropped until the final, separate release. Each schema change is its own
approved database phase (migration-pattern §8).

| Table / column | Owner | Shape |
|---|---|---|
| `employee_attendance_requirements` | WF | `business_id`, `user_id`, `status` string NOT NULL — `required` / `not_required` / `not_reviewed` (check constraint; `not_reviewed` written only by the backfill, L11), `effective_from` date NOT NULL, `changed_by_id` NOT NULL, `source` (`creation` / `backfill` / `hr_change`), `effective_date_basis` for backfill rows (`hire_date` / earliest record, L12), `reason` text (required when backdated — service rule), `created_at`; unique (`user_id`, `effective_from`); append-only (no update path). First row at employee creation with HR's explicit selection, effective from the HR-selected employment start date (L10, L18). *(Revision 2's `required` boolean is replaced by `status`, because L11 makes Not Reviewed an explicit recorded value.)* |
| HR exception list (L12 (3)) | WF | **[P]** derived, not stored: existing employees with no history row after the backfill; or a small WF table if HR needs notes per employee; visible, legacy behaviour, no invented dates (L25) |
| `users.requires_attendance` | WF (cache) | boolean nullable, no default; NULL = not reviewed (or no row); written only by the change service in the history row's transaction; never in `UserPolicy::EMPLOYMENT_ATTRIBUTES`; never read by the invariant checks (L4) |
| Invariant lock | WF | no table: a `pg_advisory_xact_lock` namespace constant owned by the WF helper (L3) |
| Rejected-attempt audit | existing audit log | no new table proposed for the entry (shape in §6.6, L8, L14); failed writes go to the durable operational record below (L20) |
| Durable audit record (L20) | infrastructure (audit, shared with `AuditLoggable`; ownership mapping needed, Appendix) | **[P]** e.g. `pending_audit_events`: `business_id` NOT NULL, full entry payload (jsonb), `attempts`, `consecutive_failures`, `last_error`, `last_attempt_at`, `next_attempt_at`, `escalated_at`, `resolved_at`, `audit_log_id`, `created_at`; one row per failed audit event = its notification (L34); never deleted, before or after resolution; retried by a Solid Queue job; the source for pending audit recovery (L29). Revision 17: also `attempted_at`, the original attempt time used as the delivered entry's `created_at` (D29); the columns as built are in §19.13. Hardening: also `entry_key` (unique idempotency key) and `dispatch_claimed_until` (sweeper claim), plus the append-only `durable_audit_receipts` (`entry_key` unique, `audit_log_id` unique) written with every AuditLog of the durable path (T-R31-11, T-R31-13) |
| Attempt log (L34) | infrastructure | **[P]** e.g. `pending_audit_event_attempts`: `pending_audit_event_id`, `kind` (`automatic` / `manual`), `actor_id` (manual only), `started_at`, `finished_at`, `result`, `error`; append-only. Revision 17: R3.1 builds `automatic` attempts only; the manual-attempt operator reference is added by R3.5 (§19.13 T-R31-4) |
| Administration alerts (L29, L34) | infrastructure (Appendix) | **[P]** no separate table: the dashboards read `pending_audit_events` and the attempt log (§6.8). The legacy `notifications` table is not used or altered (revision 5's reuse proposal withdrawn). Not built today (§3.6) |
| Leave policy (L22, L26) | WF | **[P]** e.g. `leave_policies` (one active per business; nullable `branch_id` / `user_id` columns reserved for later scopes, unused now) with `accrual_frequency` (`monthly` / `quarterly` / `semi_annually` / `annually`), `max_carry_over_days` decimal(5,2) (initially 5.00), `termination_settlement` (`paid` / `forfeited`, configurable, L26; labelled `Pay Out` / `Forfeit` in Business Settings, kept available, D19) and tier rows (`min_completed_service_years`, `days_per_year` decimal(5,2): 0 → 15, 1 → 21, 10 → 30); versioned by `effective_from` so changes never rewrite past accruals. The 31 March carry-over expiry is an approved rule, not a setting; the leave year is per employee from the Employment Start Date anniversary (L31), not a policy column |
| Leave balance ledger (L26, L31) | WF | **[P]** e.g. `leave_balance_transactions`: `business_id`, `user_id`, `kind` (`accrual` / `usage` / `cancellation` / `forfeiture` / `carry_over` / `expiry` / `termination_settlement`), `amount_days` decimal(6,2) signed, `effective_on`, `leave_year_start`, `batch_id` (the entitlement or carry-over batch it adds to or consumes), `policy_id` and tier reference, `leave_request_id`, `actor_id`, `created_at`; append-only, never updated or deleted; balance = Σ, never negative (checked under a per-employee lock at approval); display rounding in views only |
| Leave batches (L31) | WF | **[P]** e.g. `leave_balance_batches`: `user_id`, `kind` (`entitlement` / `carry_over`), `source_leave_year_start`, `amount_days` decimal(6,2), `expires_on`, `created_at`; one row per leave-year entitlement and per carry-over, never merged; FEFO orders by `expires_on` |
| Leave approval routing (L27, L33) | WF | **[P]** business-level routing settings: approver rule per employee position (branch employee / branch manager / central), Area Manager or HR for branch managers, the designated approver for central employees, and a mandatory fallback approver chain (Q45 (g)); a configuration without a valid fallback is refused |
| Leave types (L33) | WF | **[P]** e.g. `leave_types`: `business_id`, `name`, `status` (`draft` / `active` / `inactive`), `balance_effect`, `attendance_effect`, `payroll_effect`, `defined_by_id`, `activated_by_id`, `activated_at`; activation refused until all three effects are set (Q45 (h)) |
| Employment Start Date (L18, L31) | WF | **[P]** `users.hire_date` as the stored value, written only by the WF creation and correction services with reason and audit; removed from `UserPolicy::EMPLOYMENT_ATTRIBUTES` |
| Deduction denominator holiday setting (L28, D11) | AP | **[P]** one business-level payroll setting for both the unpaid-leave and the absence denominators, e.g. `exclude_public_holidays_from_deduction_denominator` boolean; default to be set by the owner at configuration |
| Transition deadlines (D1 (1) with D10; D9) | WF | **[T]** two plain dates per business in a WF-owned business-level setting (WF never reads payroll periods): the Not Reviewed deadline and the legacy-schedule deadline. Each is the last day of the business's second complete Payroll Period after the deployment of R3.3 or R4 (§18.7.2 K22), computed once at deployment by a reviewed operational task and recorded with an audit entry; shown on the not-reviewed and missing-schedule reports; AP reads the D9 date (allowed AP → WF) |
| Held termination settlements (D18) | WF (the balance and its history) with an HR/Payroll review case | **[T]** a pending review record referencing the employee, the leave balance in days as of the employment end date, an immutable termination-policy snapshot (policy, its version id and effective date, business id; D21), the reason (no schedule, not required to attend), `created_at`, and each later step with actor, timestamp and reason; append-only status changes (pending → HR reviewed → Payroll approved → released, D20 (2)–(4)); release refused while any D20 condition is unmet, including while no payout calculation is formally approved (D20 (1)); the release applies the termination-policy snapshot (D21) and writes exactly one ledger entry for the held amount, a `termination_settlement` payout under `Pay Out` or a `forfeiture` under `Forfeit`; no ledger entry is written before release and none is ever deleted; permissions and rejected reviews OT9; one person may record both steps when the configured permissions allow it (D23) |
| Post-lock leave review items (L21) | AP | **[P]** a review-item record (or a category of the Historical Violation review report) referencing the leave request, its dates, approval timestamp and the locked period; closed with an audited reason |
| Leave requests (or a leave type of `employee_requests`), approval status, dates | WF (L15) | **[P]** shape designed in R6b; type from `leave_types` above; daily-paid employees may only use unpaid types (L6, D8 (a)); balance from the ledger above; approver, approval and cancellation timestamps kept (L21, L27); cancellation requests as separate records with their own approval (L33); the HR/Payroll Review case for post-lock cancellation requests |
| Historical Violations | AP (L17) | **[P]** e.g. `attendance_invariant_violations`: `business_id`, `user_id`, conflicting date range, salary profile and requirement row references, `detected_at`, detection source, status, resolution reason / actor; append-only status changes: open → HR facts reviewed → Payroll impact reviewed → (correction executed → correction approved) → closed (with corrective action and reason); executor and approver recorded separately; no delete path (L24); permissions L30 |
| Historical payroll correction requests (L35) | AP | **[P]** e.g. `historical_payroll_corrections`: `business_id`, `violation_id` (nullable for post-lock leave cases), `status` (`pending_approval` / `approved` / `rejected`), `prepared_by_id`, `justification`, `data` (jsonb), `approver_id`, `approved_at`, `approved_via` (`finance_approver` / `super_admin_fallback`), `fallback_reason`, `rejected_by_id`, `rejected_at`, `rejection_reason`, `resubmission_of_id`; never deleted; no expiry |
| Finance Approver designations (L35) | OA [P] | **[P]** e.g. `historical_correction_approvers`: `business_id`, `user_id`, `designated_by_id`, `designated_at`, `removed_by_id`, `removed_at`; removal ends a row, never deletes it; a designee must hold `approve_historical_payroll_corrections`; a business setting `allow_same_person_correction_approval` (default false, opt-in) |
| `shift_assignments.working_weekdays` | WF | `smallint[]` nullable + check constraint (1–7 values in 0..6, Sunday = 0 as `Date#wday`); NULL only for pre-existing rows; model requires it on create (A7) |
| Holiday Calendar (e.g. `holidays`) | WF **[T]** | `business_id`, `date`, `name`, `kind` (`public` / `company`), `created_by_id`; unique (`business_id`, `date`); one business-wide calendar, no `branch_id` column in this phase (D3) |
| `cost_allocation_rules` | FS | `business_id`, `name`, `active` |
| `cost_allocation_rule_versions` | FS | `rule_id`, `effective_from`, `created_by_id`; immutable once referenced by a snapshot |
| `cost_allocation_rule_branches` | FS | `version_id`, `branch_id`, `percentage` decimal(5,2); Σ = 100.00 per version (validated in the service + a deferred check) |
| `employee_cost_allocations` | FS | `user_id`, `rule_id`, `effective_from`, `effective_to` |
| `payroll_cost_allocations` (snapshot) | FS | `payroll_period_id`, `user_id`, `component` (`salary` / `employer_insurance`), `branch_id`, `amount` decimal(12,2), `rule_version_id`, `voided_at`, `voided_by_id`; never updated except voiding |
| `expenses.unallocated` + `expenses_unallocated_payroll_only` | FS | **kept** for history (H); no new writes after the switch |
| `users.requires_shift_assignment` | WF | kept, then `ignored_columns`, then dropped in a separate final release |

**Transition sequence (A1, A2, L4, L10–L12, L17):** (1) add the history table and the cache (all NULL = not
reviewed); (1a) **backfill every existing employee** (L11): daily-paid → `required`, everyone else → `not_reviewed`
(monthly never implies not required), written through the service's code path under the invariant lock with source
`backfill`; effective date by L12 precedence — valid `hire_date`, else the earliest reliable employment or salary
record (L19 — `hire_date` only when it does not conflict with reliable records), else **no row** and the employee is placed on the HR exception list (no date invented); (1b) a
read-only check finds any invariant conflict and records it as a Historical Violation (L17) — no locked period is
touched; (1c) from this step every new employee is created with HR's explicit selection and a first row from the HR-selected employment start date (L10,
L18); (2) read-only
export of employees with `requires_shift_assignment = false` and of all employees for HR review; (3) HR records
requirements through the service; "not reviewed" report available; (4) at the review deadline (D1 (1): the end of the
second complete Payroll Period after R3.3 is deployed, D10) enforcement becomes mandatory; (5) remove the old checkbox and permitted attribute, `ignored_columns`; (6) drop the old column
in its own release. The old flag keeps its single effect (the Assign Shift picker) until step 5.

---

## 9. Historical data and snapshot policy

* **[A]** Assignments, attendance records and finalized payroll are never reinterpreted because of a requirement
  change (A5); requirement checks use the value in force on each date.
* **[C]/[A]** Finalized and paid periods are locked (`PayrollPeriod#locked?`); schedule changes never edit an
  assignment overlapping a locked period — end + successor (strategy A).
* **[P]** Cost attribution for a finalized period is read from `payroll_cost_allocations`. Periods finalized before
  the switch have no snapshot rows and keep today's report computation byte for byte, including their historical
  Unallocated line (H), relabelled "Historical unallocated" / "Historical unattributed".
* **[A]** No automatic redistribution of old salary, insurance or expense records (H). Corrections need a separate
  decision and audited compensating entries (void + repost).
* **[P]** Reopen voids the insurance expense (today) **and** the snapshot rows; re-finalization writes new rows
  resolved by Q7/Q8; both are audited. Snapshot rows are never edited.
* **[A]** Approved expense allocations are immutable snapshots (D): system-generated expenses already block business
  column changes (`Expense::SYSTEM_GENERATED_MUTABLE_ATTRIBUTES`, `app/models/finance_sales/expense.rb:96-100`);
  **[P]** extend the same guard to approved manual expenses' allocation rows.
* **[A]** No new Unallocated amounts in finalized reports; old ones stay visible only with the historical label.
* **[A]** The daily-paid invariant is validated over the complete effective-dated history (L5); salary profiles and
  requirement rows are preserved, never rewritten to satisfy it (L2, L7). A historical conflict inside a locked,
  finalized or paid period never reopens, recalculates or modifies that period; it is recorded as a Historical
  Violation, shown on the HR/Payroll review report, and any financial correction goes through a separate audited,
  authorised and approved process; historical amounts are never redistributed or altered automatically (L17, L24); a violation is never deleted, only closed with an audited reason.
* **[A]** Backfill rows record where their effective date came from (L12); no date is invented — employees without a
  reliable date stay on the HR exception list until HR completes their backfill.
* **[A]** Leave approved after the payroll period is locked keeps its actual dates and approval timestamp, never
  reopens or changes locked payroll, and is flagged for HR/Payroll review; any financial correction is a separate
  audited process (L21).
* **[A]** HR-exception-list employees: no employment date or attendance history is invented, and existing attendance
  and payroll history is never reinterpreted (L25).
* **[A]** Leave balances: earlier accruals are preserved across tier transitions, each period stays at its own rate,
  and balance and settlement history are kept (L26). **[P]** Forfeiture, expiry, cancellation and settlement are new
  ledger entries; no entry is ever edited or deleted.
* **[A]** Cancellation of approved leave that affected locked payroll never modifies that period; the case goes to
  HR/Payroll review and any correction is a separate audited process (L27). Such leave is not cancelled: the original
  leave and payroll history stay unchanged (L33).
* **[A]** Leave accruals are never recalculated after a tier change; each carry-over batch keeps its source, amount
  and expiry; each consumption keeps the batch it used (L31). A service-date correction is audited with old and new
  values (L31); **[P]** it applies prospectively (Q45 (f)).
* **[A]** Resolved audit-failure notifications, their retries and failure history are kept (L34).
* **[A]** Historical correction requests never expire; rejected requests are kept unchanged; a resubmission is a new
  linked record; removing a Finance Approver never rewrites earlier approvals or audit records (L35).

---

## 10. Payroll and financial approval gates

| Gate | Where | Rule |
|---|---|---|
| Requirement change | WF change service | A5, D4 (refused once an affected period is Under Review or later); daily-paid invariant direction 2 through the WF-defined contract (L1–L3) |
| Salary profile create / correct | `Salary::ProfileUpdater`, `Salary::ProfileCorrector` (AP) | daily-paid invariant direction 1, whole timeline, under the invariant lock (L1–L3); the admin `salary_type` / `effective_from` correction stays and passes the same check (L2) |
| Employee creation | WF change service, in the employee's creation transaction | mandatory explicit HR selection, no default; first history row from the employment start date; creation rejected without them (L10, L18) |
| New daily salary profile for a Not Reviewed employee | `Salary::ProfileUpdater` (AP) | rejected until HR sets required (L13) |
| Leave approval | WF leave workflow | routed approver per L27 / L33 (configurable) with a valid fallback; never automatic, never self-approval (L33); only approved leave has an attendance or payroll effect (L15, L27); only active leave types (L33); daily-paid: unpaid types only (L6); paid annual leave refused when the available balance is insufficient, consumed FEFO (L31); approved after a lock: kept with real dates and approval timestamp, flagged for review (L21) |
| Leave cancellation | WF leave workflow | employee-requested; the request alone cancels nothing; approved at the original approval level; only while the leave has not affected locked payroll — otherwise the leave stays unchanged and an HR/Payroll Review case is opened (L27, L33) |
| Service-date correction | WF correction service | permission, mandatory reason, audit of old and new values, actor, timestamp; never triggered by branch or job changes (L31) |
| Historical Violation correction | separate process | HR reviews facts (`manage_employees`), Payroll the financial impact (`view_payroll`); preparation `manage_historical_payroll_corrections`, approval `approve_historical_payroll_corrections` by a designated Finance Approver (Super Admin only when none exists); executor ≠ approver unless opted in; approved once only, under lock; rejection needs a reason and has no financial effect; never automatic; never deleted, closed with an audited reason (L17, L24, L30, L35) |
| Assignment save | `ShiftAssignment` validation | A4, A7; new assignment without weekdays rejected (L9 (3)); new regular assignment overlapping the same employee's regular assignment at another branch rejected (D5 (a)) |
| Payroll review warnings (from submit-for-review on) | AP, period page + anomalies | legacy undefined-schedule days and partly unscheduled periods (A7, L9 (1), D12) until the D9 deadline; not-reviewed and HR-exception-list employees (A2, L25); employees whose rule is missing (preview of the Finance readiness check); monthly unpaid-leave days whose schedule or denominator is missing or invalid (L23, L28); those employees are Flagged for Review (L32), except monthly-paid employees without a work schedule, whose unpaid leave uses Calendar-day Proration (D16, only when not required to attend, D17); employees with a held termination settlement (D18) |
| Payroll finalization | `Payroll::Approver#advance`, in the transaction, before `period_finalized` | C (required employee without applicable assignment and schedule, AP, L9 (2)); legacy undefined weekdays do **not** block until the D9 deadline (L9 (1), D12) and block under C after it; `allocation_blockers` (Finance, K); existing refusals unchanged; employees Flagged for Review under L32 are blocked individually while the others finalize (principle D7; the mechanism is designed and approved in R7.0, and not available until then) |
| Release of a held termination settlement (D18) | WF review case; AP for any payout | only after all four D20 conditions: a formally approved payout calculation for employees who do not require attendance (1), HR review of employment details and balance (2), Payroll approval of the amount (3), then the configured setting applied (4, D19); never automatic; `Forfeit` never applied while held and never converted into `Pay Out`; a payout after the final period is locked follows a separate audited process, never reopening the period (OT9) |
| Insurance expense | Finance, inside `period_finalized` | fully allocated, rule version = salary's (E) |
| Manual expense approval | `Finance::ExpenseApproval#approve!` + model | complete allocation (already); **new**: active and in-scope branches for new allocations (D) |
| Recurring template save | `RecurringExpense` validation | complete allocation (D) |
| Reports | Reporting | Provisional (draft / under review / branch review completed, live with current rules) vs Finalized (snapshot) — separate columns or lines, never summed without labels (F) |

---

## 11. Permissions and audit

| Item | Rule |
|---|---|
| Requirement change | `manage_employees`, within `UserPolicy#update?` management scope; not on self; audit `attendance_requirement_changed` {old, new, effective_from, reason, backdated} (A5) |
| Requirement at employee creation | HR's mandatory explicit selection; same service and audit, written with the employee (L10) |
| Salary profiles | permissions unchanged (`manage_salary_profiles`, `SalaryProfilePolicy`); invariant refusals are service errors, not policy errors; successful changes audited as today |
| Rejected invariant attempts | audited (L8, L14): target employee, attempted operation, current and requested values, conflict reason, actor, date/time; written in a separate transaction after the rollback (§6.6); a failed audit write raises an operational alert and is retried / recovered, never swallowed: durable operational record, background retry, administrator alert on the administration notifications dashboard if failures continue (L20, L29, L34) |
| Backfill | each row audited with source `backfill` and its effective-date basis (L12); the HR exception list and each HR completion audited |
| Leave | approvers routed per L27 / L33 (branch manager; area manager or HR; HR or designated approver), configurable, with a mandatory valid fallback; self-approval prohibited even for holders of approval permissions (`Approvals::SelfApproval`); no automatic approval; fallback chain and approver identification per the Q45 (g) recommendation; audit of request, approval, rejection, cancellation request and cancellation approval; every balance ledger entry, leave-type definition and activation, and every leave-policy or routing setting change audited (L22, L26, L27, L31, L33) |
| Service-date correction | WF permission (**[P]** `manage_employees` within scope, as A5); mandatory reason; audit {old, new, actor, timestamp} (L31) |
| Historical Violations | HR fact review `manage_employees`; Payroll financial review `view_payroll`; correction prepared with `manage_historical_payroll_corrections` and approved with `approve_historical_payroll_corrections` (L30, L35); detection, status changes, preparation, approval, rejection (with reason) and resubmission audited, executor and approver recorded separately; never deleted, closed with a reason (L17, L24) |
| `manage_historical_payroll_corrections`, `approve_historical_payroll_corrections` | new OA permissions, independent of each other and of every ordinary payroll permission (L35); business-level, not scopable; **[P]** both depend on `view_payroll` (a requirement, not a grant); defaults: HR → manage, Finance Manager / designated financial approver → approve, no automatic grant to unrelated roles — archetype mapping Q43; owners hold both implicitly, so the service enforces L35 by identity (§6.9) |
| Finance-Approver management | separate HR permission (name Q43), own business only; Super Admin intervention kept; every addition, removal and change audited (L35) |
| Same-person correction exception | business-level opt-in setting, default off; changes audited (L35) |
| Audit-failure dashboards and Retry Now | System Administrator (D1: the WorkPulse platform operations team; identity design G1): system-wide view and Retry Now; Business-level responsible person: own business, view only (Q42 (c)); each manual retry audited with actor, timestamp and result (L34) |
| Held termination settlement (D18) | creation, HR review, Payroll approval and release audited with actor, timestamp and reason; the release records the setting applied (D19, D20); the HR and Payroll permissions and whether one person may perform both steps are OT9 (precedent: the Historical Violation split in §10, HR `manage_employees` and Payroll `view_payroll`) |
| Assignments | unchanged (`assign_shifts`); refusals are validation errors, not policy errors |
| Holiday Calendar | `manage_holidays` (**[T]**, business-level; one business-wide calendar, D3); audit create/update/delete with date and kind |
| `manage_cost_allocations` | new permission in OA (`PERMISSION_GROUPS`, likely the `expense_administration` group or a new `cost_allocation` group; `PERMISSION_DEPENDENCIES` per Q13); added to `BRANCH_SCOPABLE_PERMISSIONS` so branch rows respect `BranchScope`; not in `DEFAULT_PERMISSIONS_BY_ROLE_TYPE` unless the owner says so; audit every rule, version and employee link (G) |
| Snapshots | written in the finalization transaction under the finalizing actor; voided under the reopening actor; no edit path for anyone (G) |
| Report privacy | branch reports: one aggregate "Allocated Central & Floating Staff Costs" line only (I, D2); individual rows require `Finance::PayrollCostAccess` (`app/services/finance/payroll_cost_access.rb`) |

---

## 12. Edge cases and failure scenarios

| Case | Expected handling |
|---|---|
| Requirement → not required with an open-ended assignment | Refused until the assignment is ended before the effective date (A5) |
| Future-dated change, then someone creates an assignment crossing that date | Assignment refused by the model validation (6.3) |
| Backdated change touching a period Under Review or later (under review, branch review completed, finalized, paid) | Refused (A5, D4); before Under Review: allowed with a reason and audit (A5) |
| Daily-paid employee set to not required (now, future-dated or backdated) | Rejected if any daily-paid date falls in the not-required range; nothing written; attempt audited (L2, L8) |
| New daily profile, or a correction to daily, for a not-required employee | Rejected in AP; nothing written; attempt audited (L2, L8) |
| Future-dated daily profile vs a future-dated not-required row | Whichever is attempted second is rejected (whole-timeline check, L2) |
| Admin correction moves a monthly profile's `effective_from` later, lengthening a preceding daily period into not-required dates | Rejected (L2) |
| Daily profile for a Not Reviewed employee | Rejected until HR reviews and sets required; other checks then apply (L13) |
| New employee created without a requirement selection or start date | Creation rejected (L10, L18) |
| New employee created as not required, then a daily salary profile | Salary profile rejected (L2, L10); no automatic change (L2) |
| Backfill: `hire_date` missing or conflicting with reliable records | Earliest reliable employment or salary record used (L19) |
| Backfill: evidence missing or conflicting | No row, no invented date; HR exception list; visible, legacy behaviour, no new daily profile (L19, L25) |
| Backfill: monthly employee never reviewed | Explicit `not_reviewed` row — never "not required" (L11) |
| Rejected attempt and the audit write also fails | Rejection still returned; nothing persisted; event kept in the durable record, retried by a background job, administrators alerted if failures continue (L14, L20) |
| Monthly-paid employee on approved paid annual leave | Not absent; salary not reduced; leave balance reduced (L16, L22) |
| Monthly-paid employee on approved unpaid leave | Not absent; deduction = applicable monthly salary ÷ scheduled working days in the payroll period × unpaid leave workdays when the whole period is eligible (L23 as refined by L28); otherwise the D15 rate over the eligible dates |
| Monthly unpaid leave with a missing or invalid schedule (e.g. legacy assignment without weekdays) | Flagged for Review; no invented denominator and no deduction calculated; that employee's finalization blocked, the others continue (L23, L28, L32; principle D7, mechanism R7.0) |
| Leave pending or rejected | No attendance or payroll effect (L15, L27) |
| Unpaid leave in a payroll period with a mid-period salary change | Each leave date priced with the profile in force that day; split at the effective-date boundary; one denominator over the eligible dates, the whole payroll period when fully eligible (L28, D15) |
| Payroll period not aligned with the calendar month | Denominator = scheduled working days in the payroll period, or over its eligible dates when only part is eligible (L28, D15) |
| Public holiday on a scheduled weekday inside a period with unpaid leave or absence | Never an absence (A10); in or out of both the L28 and the D5 (b) denominators per the one business setting (D11) |
| Employee crosses a service tier (e.g. completes 10 full years) | Accrual split at the qualification date: old rate before, new rate after; earlier accruals never recalculated (L26, L31) |
| Accrual of a fraction of a day | Stored to two decimals, never rounded to a whole day; display rounding only (L26) |
| Balance above the carry-over cap at the leave-year anniversary | Excess forfeited by a ledger entry; at most the cap (initially 5) carried as a new batch (L26, L31) |
| Carried-over days unused by 31 March of the year after the carry-over year (D8 (b), D14) | That batch's remainder expires by a ledger entry; other batches unaffected (L31) |
| Carry-over shortly before 31 March | The batch expires on 31 March of the following calendar year, not within days: carried over on 30 March 2026 → expires 31 March 2027 (D8 (b), D14) |
| Paid leave while a carry-over batch and current entitlement both exist | FEFO: the batch closest to expiry first; each usage entry names its batch (L31) |
| Employee joins or leaves mid leave year | Entitlement prorated by eligible service (L31; formula Q45 (b)) |
| Accrual while on unpaid leave | Continues (L31) |
| HR corrects the Employment Start Date | Reason and audit required; tiers and leave year follow the new date prospectively, no past entry rewritten (L31; Q45 (f)) |
| Employee changes branch or job | Service date unchanged (L31) |
| Employee leaves with unused balance | Settled or forfeited per the business setting; balance and settlement history kept (L26, L31; payout per D6 as a separate Final Payroll line; end date Q5 **[T]**); without attendance requirement and schedule: held for review under either setting (D18, D19), released only under D20 |
| Paid leave requested beyond the available balance | Refused; no negative balance; the employee may request unpaid leave instead (L31) |
| New leave type without all three effects defined, or not approved | Cannot be activated or requested (L33) |
| Daily-paid employee and a paid leave type | Unpaid types only (L6, D8 (a)) |
| Branch manager requests leave | Routed to the Area Manager or HR per the business setting (L27, L33); no valid approver → fallback chain, never auto-approved (L33; chain Q45 (g)) |
| Requester is the routed approver | Self-approval refused; routed to the fallback or a higher level (L33) |
| Employee requests cancellation of approved leave | The request alone cancels nothing; approved at the original level; consumed batches restored; open periods recalculated (L27, L33) |
| Cancellation of leave that already affected a locked period | Not cancelled; leave and payroll history unchanged; HR/Payroll Review case; separate audited correction (L27, L33); partly locked leave treated as affected (Q45 (e)) |
| Audit write keeps failing | Durable record retained, job retries; escalated after 3 consecutive failures; one notification updated in place, never duplicated; Resolved on success, never deleted (L29, L34) |
| System Administrator presses Retry Now while the job is retrying | Row lock: one attempt runs, the other is refused or skipped; the manual attempt's actor, time and result recorded (L34) |
| Business-level user requests another business's notification by id | Not found: the query is scoped by `business_id`, not the UI (L34) |
| Business-level user tries Retry Now | Refused: System Administrator only (L34) |
| One user both executes and approves a Historical Violation correction | Refused by default; allowed only when the business opted in; executor and approver still recorded separately (L35) |
| Two Finance Approvers approve the same correction at once | Row lock and status re-check: exactly one approval; the other is refused (L35) |
| Super Admin approves while a Finance Approver exists | Refused; allowed only when the pool is empty, with a recorded reason (L35) |
| HR removes the last Finance Approver with corrections pending | Allowed; corrections stay Pending Approval and route to Super Admin; nothing deleted or rewritten (L35) |
| Correction rejected | Reason required; kept permanently; no financial effect; HR may resubmit as a new linked request (L35; no maximum, D8 (c)) |
| Owner (implicitly holding both permissions) prepares and approves | Refused unless the opt-in exception is on; owner approves only as a designated Finance Approver or through the fallback (L35, §6.9) |
| Daily-paid employee requests paid leave | Not available — unpaid leave only (L6) |
| Requirement change and daily profile submitted at the same moment | Serialised by the invariant lock; the second re-checks and is rejected (L3) |
| Daily → Monthly conversion | New monthly profile; requirement unchanged; a later "not required" change still rejected for remaining daily dates (L7) |
| Daily-paid employee on approved unpaid leave | Not absent, not paid, no deduction; requirement and salary type unchanged (L6; WF leave, L15) |
| Leave approved for a date in a locked period | Keeps its real dates and approval timestamp; locked payroll untouched; flagged for HR/Payroll review; any correction is a separate audited process (L21) |
| Historical conflict found in a locked period | Recorded as a Historical Violation and shown on the HR/Payroll report; period untouched; correction only through the separate authorised, audited process (L5, L17, L24); HR reviews facts, Payroll the financial impact; closed with an audited reason, never deleted |
| Not-reviewed employee after the deadline (end of the second complete Payroll Period after R3.3 is deployed, D1 (1), D10) | Enforcement (R5) refuses new assignments until reviewed |
| Regular + temporary coverage on the same dates | Coverage wins per date (P9); coverage also needs working weekdays (A7) |
| Two concurrent regular assignments at different branches, disjoint weekdays | New ones refused (D5 (a)): use temporary coverage or a floating assignment; existing overlaps stay valid, are reported, and keep today's per-date winner (P9) |
| Schedule change (end + successor) for an employee with an existing cross-branch overlap | **[T]** The successor is a new assignment, so it is refused while the overlap remains; HR first ends one of the overlapping assignments, listed in R4's report (D5 (a), strategy A) |
| Absent day and approved unpaid leave on the same date | The date is on leave, not absent; one deduction only (D5 (b), L6, L28) |
| Monthly absence in a period with a mid-period salary change | Each absent date priced at the profile in force that day; split at the boundary; one denominator over the eligible dates, the whole payroll period when fully eligible (D5 (b), D15) |
| Employee Flagged for Review under L32 | Held: the others are finalized and paid on time; the held entry keeps being calculated, then is finalized and paid later in the same period; its cost is Provisional until released (D7; mechanism R7.0) |
| Leaver whose business settles unused leave as paid | Remaining eligible days × the D5 (b) daily rate over the eligible dates of the final period (D13, D15), a separate Final Payroll line; settlement ledger entry; with "forfeited", a forfeiture entry instead (D6, L26, L31) |
| Floating employee | Exclusive assignment (model); own weekdays; biometric at any branch (PR #110); rule required (J) |
| Mid-month hire / leaver | Bounded by employment window (Q5); no absence outside the assignment window (C) |
| Assignment ends mid-month, no successor, employee still active and required | Blocks finalization for the uncovered dates (C) |
| Holiday on a scheduled weekday | Not counted as absence (A10) |
| Legacy assignment without weekdays | No deduction for those days, warning; finalization allowed under the legacy exception until the end of the second complete Payroll Period after R4 is deployed (A7, L9 (1), D9, D12) |
| Legacy assignment without weekdays after the D9 deadline (required employee) | Those dates have no working schedule: finalization blocked under C (L9 (2)) until HR ends the assignment and creates a successor with working days (strategy A; D5 (a) applies to the successor) |
| Period partly on a legacy assignment without weekdays and partly on one with weekdays (before the D9 deadline) | Unscheduled dates: no deduction, nothing estimated, warning; scheduled dates: normal absence calculation (D12), priced at the D15 rate over those dates only; finalization allowed. Unpaid leave on an unscheduled date: Flagged for Review (L32) |
| Joiner or leaver with a partial Payroll Period | Absence and unpaid leave priced at the D15 rate: salary attributable to the employment dates ÷ scheduled working days among them; never the full monthly salary against the partial denominator. A leaver's payout uses the same rate for the final period (D13, D15) |
| Example (D15): monthly salary 3,000 for a 30-day period; employee joins on day 16; 13 scheduled working days in days 16–30; absent 1 day | Numerator = salary attributable to days 16–30 (1,500 on a calendar-day basis, OT3); rate = 1,500 ÷ 13 ≈ 115.38; deduction ≈ 115.38. Never 3,000 ÷ 13 ≈ 230.77 |
| Salary change inside a partial window | Split at the change; each date priced at its own profile over the same eligible dates (D15; segment handling OT2) |
| Leaver whose final period has no scheduled working day in the employment window | Required to attend: the rate of the D22 reference period (the last preceding reliable Payroll Period with scheduled working days), at the end-date salary (D26) over its reliably scheduled dates (D27), recorded with the settlement; no reference period: pending HR/Payroll review, never paid, forfeited, zeroed or discarded (D25). Not required to attend and no schedule: D18 |
| Monthly-paid employee without any schedule (e.g. central) on approved unpaid leave | Calendar-day Proration (D16): no assignment or schedule created, no division by zero scheduled days; formula details OT4–OT8. Not Flagged for Review merely for having no schedule |
| Central employee: absence | None: not required to attend, no scheduled days, so no absence (B, A4); D16 does not apply to absence |
| Required employee whose schedule is missing on an unpaid-leave date (no assignment, or a legacy assignment without working days) | Never Calendar-day Proration (D17): C blocks finalization where it applies; otherwise Flagged for Review (L32); payroll-review warning (D12) |
| Not Reviewed or HR-exception-list employee without a schedule on approved unpaid leave | Not "not required" (A2, L4, L25), so never D16 (D17); Flagged for Review (L32) |
| Employee whose requirement changes during the period (required ↔ not required) | Each date by its own requirement: not-required dates by D16, required dates by D15 or the existing controls; combining the two parts is OT6 |
| Employee with a schedule for part of the period and none for the rest (e.g. becomes central mid-period) | Scheduled-day proration (D15) for the scheduled dates; how the unscheduled dates are prorated, and how the two parts combine, is OT6 |
| Central employee leaves with an unused balance | Settlement held for HR/Payroll review (D18): pending review case, balance and full history preserved, no automatic payment, no forfeiture, erasure or zeroing; the final payroll is finalized without a payout line; held under `Pay Out` and `Forfeit` alike (D19); released only after every D20 condition, then the configured setting applied |
| Carry-over batch would expire after the employment end date while a D18 settlement is held | No expiry entry: the held amount is the balance as of the employment end date (D18 forbids reducing it); no accrual after the end date (L31 proration) |
| Required employee leaves and the final period has no scheduled working day | Not covered by D18: the D22 reference-period rate, never Calendar-day Proration (D17); scope, reference period and salary: D24–D27 |
| Held settlement, business setting `Forfeit` | Never forfeited while pending (D19); after every D20 condition is met, one recorded forfeiture entry for the held days, with the HR and Payroll review history; never converted into a payout. D20 (1) applies under `Forfeit` too (§18.11.2 K63) |
| Held settlement, business setting `Pay Out` | After every D20 condition is met, a payout at the formally approved calculation (D20 (1)), never an assumed rate; the final period is normally locked by then, so it is paid through a separate audited process, never by reopening the period (OT9) |
| Held settlement, no payout calculation approved yet | Stays pending, listed on the HR/Payroll review report; **[T]** HR's review may already be recorded, but Payroll cannot approve an amount and nothing is released (D20 (1)) |
| HR has reviewed but Payroll has not approved, or rejects the amount | Still pending; the balance is unchanged; the rejection is kept in the review history; how the case returns for review is OT9 |
| Business changes its termination setting while a settlement is held | No effect: the D21 snapshot taken at the employment end date is applied at release; the held balance and its history are unaffected |
| New assignment without weekdays (any path) | Rejected (L9 (3)) |
| Central employee without a rule | Finalization blocked (B, K) |
| Rule branch deactivated later | Existing versions keep it (history); new versions refuse inactive branches (D) |
| Rounding with many branches and employees | One shared `MoneySplitter`: 2 dp, remainder to a deterministic row (largest share, then lowest branch id); per-employee and per-component sums exact |
| Reopen → rule changes → re-finalize | Q8; audited |
| Insurance with zero salary or vice versa | Split by the same percentages; zero amounts produce no rows |
| Report for a month mixing finalized and open periods | Finalized lines from snapshots, provisional lines labelled (F) |

---

## 13. Phased implementation roadmap

| # | Phase | Domain | Depends on |
|---|---|---|---|
| R0 | Read-only production queries (authorised operator): employees by `requires_shift_assignment`; employees with payroll entries and no assignment in the last 3 periods; current assignments (all kinds); floating assignments; unallocated and unattributed expenses; recurring templates with incomplete allocation; for the L11/L12 backfill: employees by salary type, employees without `hire_date`, `hire_date` later than their earliest salary / assignment / attendance record, and employees with no reliable date (expected HR exception list) | — | — |
| R1 | Documentation: `CLAUDE.md` business rules; `module-boundaries.md` §3.3 and §14.1 A; module-boundaries §12.1 for the L1 contract; floating plan supersession (done as a note, see the Appendix) | — | owner review of this plan |
| R2 | `MoneySplitter` extraction — behaviour-preserving | FS | — |
| R3 | Attendance requirement history (`status`: required / not required / not reviewed), change service, cache, three-state UI, not-reviewed report, audit; mandatory explicit selection and first row at employee creation (admin and data-request approval) (L10); all-employee backfill with L12 date precedence and the HR exception list (L11, L12); the daily-paid invariant in both directions — WF read API, invariant lock helper, WF-defined check contract + AP implementation and initializer, checks in `Salary::ProfileUpdater` / `ProfileCorrector`, Not Reviewed rule (L13) (L1–L3); rejected-attempt audit in a separate transaction, durable record, background retry and administrator alert (L8, L14, L20); the administration notifications dashboard and its integration with the `notifications` table for audit-failure alerts (L29); escalation, one-notification-per-event, Resolved state, attempt log, tenant-scoped Business-level dashboard and System-Administrator Retry Now with per-event locking (L34); mandatory HR-selected employment start date (L18) and its audited correction service (L31); backfill evidence rule (L19); exception-list behaviour (L25) | WF + AP (+ audit infrastructure) | R1; D4 (backdating) and D1 (platform roles) decided — split and readiness in §18.4 |
| R3b | Historical Violations: AP records, read-only detection after the backfill and then periodically, HR/Payroll review report, HR fact review and Payroll financial review, closing by audited corrective action with reason, never deleted (L17, L24); the two new permissions `manage_historical_payroll_corrections` and `approve_historical_payroll_corrections` and the separate execute / approve steps (L30); correction requests, Finance Approver designations and their management permission, approval under lock, Super Admin fallback, opt-in same-person exception, rejection with reason, linked resubmission (L35); post-lock leave and leave-cancellation review items (L21, L27, L33) once R6b exists | AP + OA (report read-only) | R3 (Super Admin = owner: D1; presets Q43 **[T]**; no resubmission maximum: D8 (c)) |
| R4 | `working_weekdays` on assignments (mandatory for new), `Shifts::ScheduleChanger` (end + successor), templates (P10), missing-schedule report | WF | R1; cross-branch overlap validation per D5 (a); its deployment starts the D9 count |
| R5 | Assignment enforcement in the model for every path; callers' error surfaces; eligibility switched to the requirement | WF | R3, R4; not-reviewed cut-off = D1 (1), counted from the R3.3 deployment (D10) |
| R6 | Holiday Calendar (model, UI, permission, audit), one business-wide calendar (D3) | WF **[T]** | R1 |
| R6b | Leave management (L15): leave types (paid / unpaid), requests, approval workflow, dates and status, entitlement and balance records; daily-paid limited to unpaid types (L6); paid annual leave reduces the balance (L16); business-level leave policy with service-duration tiers and accrual frequency, extensible to branch / employee scope later (L22); append-only two-decimal balance ledger, tier transitions, carry-over cap with forfeiture, 31 March expiry, termination-settlement setting and history (L26); a held settlement (D18) keeps the balance as of the employment end date, writes no settlement, expiry or forfeiture entry while pending, and is listed for HR/Payroll review; it is held under either setting (D19) and released only through the D20 steps (HR review, Payroll approval, setting applied), each audited; configurable approval routing and cancellation with same-level approval (L27); anniversary leave year, proration, tier split, no negative balance, carry-over batches, FEFO, accrual during unpaid leave (L31); configurable leave types with defined effects and activation, fallback approvers, self-approval ban, cancellation rules (L33); approval timestamp kept, approvals after a lock allowed and exposed for review (L21); audit; read API for AP (approved leave only) | WF | R1, R3 (service date), the Q5 column **[T]**; daily-paid unpaid only (D8 (a)); expiry per D8 (b) and D14; other Q45 details **[T]**; D18–D21 decided; OT9 resolved (§19.3) except Q53 |
| R7 | `Payroll::ScheduledDays` and date-based absence priced per D5 (b), with a Parity Report before rollout (6.4); attendance-data blockers (C, L9 (2)), legacy warnings (L9 (1)) until the D9 deadline and blocker C after it, partly unscheduled periods (D12); effect of approved leave — daily-paid unpaid leave (L6), monthly-paid paid and unpaid leave (L16) with the L23 / L28 unpaid-leave deduction (payroll-period denominator, per-date salary profile, holiday-exclusion setting shared with absence, D11) and review flag; Calendar-day Proration for monthly-paid employees who do not require attendance (D16, D17); termination settlement held for review for employees without attendance requirement and schedule (D18), with any payout after release only at the calculation approved under D20 (1); post-lock leave and cancellation flags (L21, L27); per-employee finalization block for Flagged for Review employees (L32); effects of configured leave types (L33); termination-settlement payout when configured as paid (L26, L31, D6, D13) | AP | R4, R5, R6, R6b, the Q5 column, **the approved R7.0 design (D7 is principle only)**; D5 (b), D6 and D9–D27 decided; OT2–OT9 resolved (§19.3), OT1 decided as D22 (details D24–D27); releasing a held settlement also waits for D20 (1); **order and prerequisites superseded by §19.10 (R10 and R11 before R7)** |
| R8 | Expense validation: active and in-scope branches for new allocations; recurring template validation on save; immutability of approved allocation rows | FS | R2 |
| R9 | Cost Allocation Rules, versions, employee links, `manage_cost_allocations`, UI, audit | FS + OA | R2 (Q13 decided **[T]**, §18.1) |
| R10 | Contract extension (K): per-employee payload, `allocation_blockers`, snapshots, fully allocated insurance, void on reopen; stop writing Unallocated | AP + FS | R7, R9, the G4 finalization-hold design (§18.2); Q6–Q8 decided **[T]** |
| R11 | Reports: snapshot-first for finalized periods; Provisional labelling; "Allocated Central & Floating Staff Costs" aggregate (D2); historical Unallocated label | Reporting | R10 (label decided: D2) |
| R12 | Old checkbox removal Release 1 (UI, permitted attribute, `ignored_columns`) | WF | R5 deployed and verified |
| R13 | Old column drop (Release 2), separate migration | WF | R12 deployed and verified |

**Revision 7:** the readiness of every phase, the R3 split (R3.1–R3.5) and the recommended order are in §18.4. They
supersede the "Depends on" column wherever the two differ.

**Revision 8:** D1–D8 are recorded in this table and in §18.4. R7.0 (the finalization-hold design gate) stays
before R7 and R10; D7 does not replace it.

**Revision 9:** D9–D14 are recorded in this table and in §18.4. The two transition deadlines are counted
separately: from the R3.3 deployment for Not Reviewed employees (D1 (1), D10), and from the R4 deployment for
legacy assignments without working days (D9).

**Revision 10:** D15 is recorded in this table and in §18.4. R7 no longer waits for an owner decision on rates,
apart from Q48 for employees without a schedule.

**Revision 11:** D16 is recorded in this table and in §18.4. Unpaid leave for employees without a schedule uses
Calendar-day Proration; its formula details (OT4–OT8) are settled in R7's design review, and Q49 is open.

**Revision 12:** D17 and D18 are recorded in this table and in §18.4. D16 is limited to employees who do not require
attendance; the held termination settlement (D18) is built in R6b (balance and review case) and R7 (final payroll
without a payout line).

**Revision 13:** D19 and D20 are recorded in this table and in §18.4. The hold applies under both settings; its
release steps (HR review, Payroll approval, setting applied) are built with the review case in R6b; a release itself
waits for the formal approval of the payout calculation (D20 (1)), which no phase in this plan delivers.

**Revision 14:** D21 is recorded. The phase order, prerequisites, scope and completion gates are consolidated in
§19.10, which supersedes this table where they differ: R10 (the contract extension with the R7.0 hold infrastructure)
and R11 (Provisional reporting) now come before R7.

The salary-advance phases (floating plan phases 10–12) keep their own order and dependencies; they read the scheduled
days from R7 where the floating plan says so.

## 14. Acceptance criteria per phase

| # | Accepted when |
|---|---|
| R0 | Owner has reviewed the counts; follow-up data clean-up (if any) is planned |
| R1 | The four documents state the same rules; no contradiction remains |
| R2 | All existing allocation and insurance specs pass unchanged; one rounding implementation |
| R3 | Requirement history is append-only; cache equals the value in force and is never read by the checks; refusals per §6.1, including every backdated change touching a period Under Review or later (D4); not-reviewed report lists exactly the employees whose value in force is not reviewed or who have no row; the HR exception list lists exactly the employees without a reliable date; audit entries carry old/new/date/actor/reason; no employee can be created without an explicit selection and a first row; every existing employee has a row or is on the exception list; every daily-paid employee with a reliable date is required after the backfill and no monthly employee is not required by inference; a Not Reviewed employee cannot receive a daily profile; the invariant holds in both directions over the whole timeline through every salary and requirement path (§6.6); concurrent opposite changes cannot both commit; a rejection leaves no row and writes a rejected-attempt audit entry in a separate transaction; a failed audit write produces an alert and is recovered by the retry path, never lost silently; after 3 consecutive failures the event is escalated with one notification updated in place, marked Resolved and kept on success; Business-level users see only their business's events and cannot retry; Retry Now is System-Administrator-only and never runs concurrently with another attempt (L29, L34); the Employment Start Date changes only through the audited correction service (L31); no WF code names an AP constant; `requires_attendance` is not a permitted employee-form attribute |
| R3b | Every conflict found by detection is recorded once as a Historical Violation and listed on the HR/Payroll report; no payroll period, entry or amount changes; status changes audited; HR review needs `manage_employees`, Payroll review `view_payroll`; a correction is executed only with `manage_historical_payroll_corrections` and approved only with `approve_historical_payroll_corrections` (L30); a correction is approved at most once under concurrency; executor ≠ approver unless opted in; Super Admin approves only with an empty pool and a reason; removing approvers never loses or rewrites a pending correction; rejection needs a reason and causes no financial effect; resubmissions are linked new records (L35) |
| R4 | No new assignment without weekdays through any path (L9 (3)); no new regular assignment overlapping the same employee's regular assignment at another branch through any path, existing overlaps untouched (D5 (a)); legacy assignments without weekdays stay valid; schedule change on a period overlapping a locked payroll creates a successor, never an in-place edit |
| R5 | A not-required employee cannot be assigned through any of the seven paths (UI, bulk, API, templates, coverage, floating, edit); not-reviewed keeps legacy eligibility until the end of the second complete Payroll Period after R3.3 is deployed (D1 (1), D10), after which new assignments are refused until reviewed |
| R6 | One business-wide holiday calendar per business, no branch-specific calendars (D3); audited; read by AP |
| R6b | Leave types, requests, approval, dates, status and entitlement records live in Workforce; only approved leave is exposed to AP; daily-paid employees cannot take paid leave; approved paid annual leave reduces the balance; tiers and accrual frequency configurable per business (L22); balances are the sum of an append-only two-decimal ledger, never rounded in storage; tier changes apply from the qualification date without touching earlier accruals; the carry-over cap forfeits the excess and carried days expire on 31 March of the calendar year after the carry-over year (D8 (b), D14); the termination-settlement setting (`Pay Out` / `Forfeit`) is honoured and recorded (L26, D19); a leaver without attendance requirement and schedule is held under either setting, with no settlement, forfeiture or expiry entry while pending, and is released only after every D20 condition, writing one entry per the setting applied, never `Forfeit` converted into `Pay Out` (D18–D20); requests route to the L27 approver and cancellations need same-level approval (L27); leave years follow each employee's anniversary; proration, tier split, FEFO and batch expiry produce the expected ledger; paid leave beyond the available balance is refused; no balance is ever negative; accrual continues during unpaid leave (L31); only active, fully defined leave types can be requested; no request is auto-approved or self-approved; a cancellation request alone changes nothing and post-lock requests open a review case (L33); approval timestamp recorded; every transition audited |
| R7 | No absence before an assignment starts or after it ends; only scheduled weekdays counted; holidays excluded; legacy undefined days warned, not deducted, and do not block finalization until the D9 deadline, after which they block under C; in a partly unscheduled period the scheduled dates are calculated normally and the unscheduled ones are neither deducted nor estimated, with a warning (D12); required employee without applicable assignment and schedule blocks finalization with the exact dates; a daily-paid approved unpaid leave day is neither absent, paid nor deducted; a monthly-paid approved paid-leave day is not absent and not deducted; a monthly-paid approved unpaid-leave day is not absent and reduces salary by the L28 formula (scheduled working days of the payroll period, or of its eligible dates when only part is eligible (D15), rest days excluded, public holidays per the setting, which applies to the absence denominator too (D11), each date at the salary profile in force); a missing or invalid denominator is flagged, never invented, and blocks only that employee's finalization (L32, per the approved R7.0 design); leave approved after a lock is flagged and changes no locked period (L21); pending or rejected leave has no effect; employees without absence or leave reproduce today's payroll; monthly absence deductions follow D5 (b) (salary profile per date, split at boundaries, scheduled working days of the payroll period or of its eligible dates (D15), no 26 divisor), and a Parity Report comparing them with today's ÷ `working_days_per_month` result is reviewed before rollout; no date is deducted both as absence and as unpaid leave (D5 (b)); held employees are finalized and paid later in the same period, their cost Provisional until release (D7, per R7.0); the termination payout is a separate Final Payroll line (D6) priced at the D5 (b) daily rate (D13); for partial schedules, joiners and leavers every rate's numerator and denominator cover the same eligible dates, no deduction uses the full monthly salary against a partial-period denominator, and a period's deductions never exceed the salary attributed to its eligible dates (D15); a fully eligible period gives the same result as the D5 (b) / L28 formula; a monthly-paid employee who does not require attendance has unpaid leave deducted by Calendar-day Proration per the approved R7 design (D16, D17, OT4–OT8), and no employee who requires attendance is ever priced by D16 (D17), with no `ShiftAssignment` or schedule created, no division by zero and no Flagged for Review for the missing schedule alone; employees with reliable schedules are unaffected by D16; no attendance, absence or classification result changes; a held settlement (D18) leaves the final payroll finalized without a payout line, and a payout after release uses only the formally approved calculation (D20 (1)), never an assumed rate |
| R8 | Inactive / out-of-scope branches refused for new allocations; incomplete recurring templates refused on save; approved allocation rows immutable |
| R9 | Versions immutable once used; Σ = 100.00 enforced; only in-scope branches selectable; permission separate from `manage_employees` |
| R10 | Finalization refused while any central or floating employee lacks a rule; snapshots written; insurance expense fully allocated with the salary percentages; reopen voids snapshot and expense; no new `unallocated: true` expense |
| R11 | Finalized months reproduce from snapshots; pre-switch months reproduce exactly as before, Unallocated labelled historical; provisional amounts labelled and not summed into finalized totals; one "Allocated Central & Floating Staff Costs" line (D2); no central or floating employee name or salary in ordinary branch reports |
| R12–R13 | No code reference to `requires_shift_assignment` remains before the drop |

## 15. Required tests per phase

| # | Tests |
|---|---|
| R2 | Splitter property specs (exact sums, deterministic remainder, many branches); existing allocation/insurance specs untouched |
| R3 | Service specs: effective dating, future-dated change with/without future assignments, backdating refused into periods Under Review or later and allowed with a reason before (D4), reason required, cache consistency, audit; creation (admin create, data-request approval): rejected without an explicit selection or a start date, first row from the HR-selected start date (L10, L18); backfill: every employee gets a row, daily-paid → required, others → `not_reviewed`, effective-date precedence (valid `hire_date` → earliest reliable record → exception list, no invented date), `hire_date` ignored when it conflicts with reliable records, missing or conflicting evidence → exception list, backfill rows audited (L11, L12, L19); request specs for the three-state form; policy specs for scope; `requires_attendance` absent from `UserPolicy#permitted_attributes` |
| R3 invariant, direction 2 | requirement → not required rejected when a daily profile is in force now, in the future, or only in the past part of the range; allowed for monthly staff and outside daily periods; rejection rolls back row and cache; contract proven with a **planted provider** whose answers differ from real data |
| R3 invariant, direction 1 | `ProfileUpdater` (admin and API): daily profile rejected for a not-required date now / later / only in the future; future-dated daily vs future not-required row; Not Reviewed and no-row (exception list) employees rejected, then accepted after HR sets required (L13, L25); `ProfileCorrector` (admin): in-place monthly → daily rejected; moved `effective_from` that lengthens a preceding daily period rejected; amount-only correction (admin and API) unaffected; nothing written on rejection; Daily → Monthly conversion leaves the requirement unchanged (L7) |
| R3 concurrency | non-transactional context, two threads: requirement change vs daily profile for the same employee → exactly one commits; different employees do not block each other |
| R3 audit | rejected attempts (both directions, admin and API) write one entry with the L8 fields in a separate transaction after the rollback; a forced audit-write failure is reported (alert) and kept in the durable record, retried by the background job until the Audit Log entry exists exactly once, and alerts administrators after continued failures escalation exactly at the third consecutive failure; one notification per event updated in place; Resolved and kept on delivery; attempt log rows for automatic and manual attempts; concurrent Retry Now / job attempt → one runs; Retry Now refused for Business-level users; cross-business request specs for every dashboard query (L29, L34); service-date correction requires reason and writes old / new audit (L31); the rejection is still returned with nothing persisted (L14, L20); successful changes audited as before |
| R3b | detection finds planted conflicts (daily profile over not-required, not-reviewed and no-row dates) and records each once; re-running is idempotent; locked periods and entries unchanged (no-writes check on payroll tables); HR and Payroll review steps; closing requires a reason and is audited; no delete path (L24); status-change audit; policy specs: HR review `manage_employees`, Payroll review `view_payroll`, execute and approve gated by their separate permissions, execute-only and approve-only users refused the other step (L30); permission dependency specs; L35: neither correction permission implies the other or is granted by ordinary payroll permissions; same-person refused by default and allowed with the opt-in; two concurrent approvals → exactly one; Super Admin refused while a Finance Approver exists and accepted with a reason when none; approver removal keeps pending corrections and routes them; rejection without reason refused; rejected request immutable; resubmission linked; owner treated by identity; cross-business specs |
| R6b | leave type, request, approval, rejection and cancellation specs; daily-paid refused paid leave types; leave-policy tiers (15 / 21 / 30) and each accrual frequency; tier qualification date mid-year (earlier accruals unchanged); two-decimal accrual with no whole-day rounding and display-only rounding; carry-over cap (5 and a configured value) with forfeiture entry; 31 March expiry of the calendar year after the carry-over year, including a carry-over on 30 March (D14); termination settlement as paid and as forfeited, history kept (L26); held settlement for a leaver without attendance requirement and schedule (D18) under `Pay Out` and under `Forfeit` (D19); release refused for each missing D20 condition (no approved calculation, no HR review, no Payroll approval); release under `Forfeit` writes one forfeiture entry and under `Pay Out` one settlement entry, never the other; review history kept; routing for branch employee, branch manager and central employee and a configured override; cancellation with same-level approval and balance restoration; cancellation of leave in a locked period → review item, period unchanged (L27); anniversary leave years; proration on joining and leaving; tier split inside a leave year without recalculation; refusal beyond the available balance; FEFO across several batches with batch references; batch expiry on its own 31 March; accrual during unpaid leave (L31); leave-type activation refused until all effects are defined; fallback routing, no-approver pending state, self-approval refused; cancellation request leaves the leave unchanged until approved (L33); balance reduction on paid annual leave (L22); only approved leave exposed to AP; approval after a lock keeps dates and approval timestamp and creates a review flag (L21); boundary spec — WF leave code names no AP constant |
| R3 requests / API | admin salary profile create / update and `POST` / `PATCH /api/v1/users/:id/salary_profiles` show the rejection (form error / 422) in EN and AR; the requirement form shows the conflicting date |
| R3 architecture | boundary spec: WF names no AP constant or table; AP implementation shape-pinned; stale-entry check; planted probe; dependency inventory classification; tenancy (another business's employee is never read or locked) |
| R4 | Constraint spec (writes bypassing validations); model specs for mandatory weekdays on create and legacy NULL rows staying valid; `ScheduleChanger` specs incl. locked-period successor; template expansion specs; cross-branch regular overlap refused on create through every path, legacy overlaps still valid (D5 (a)) |
| R5 | Path-matrix request/service specs (UI, bulk, API, templates, coverage, floating, edit) for required / not required / not reviewed, before and after the D1 (1) deadline (D10); a boundary spec that every `ShiftAssignment` creation path goes through the validation |
| R6 | Model, policy and request specs; audit |
| R7 | `ScheduledDays` per-date specs: mid-month start/end, successive assignments (rotation), coverage overlap, floating, holidays, legacy undefined weekdays (warning, no deduction, finalization allowed), requirement change mid-period, partial employment; daily-paid approved unpaid leave (not absent, not paid, no deduction); monthly-paid approved paid leave (not absent, no reduction) and unpaid leave (not absent, L28 formula over the payroll period's scheduled working days, rest days excluded, public-holiday setting on and off, a payroll period crossing two calendar months, a salary change inside the period split by date; missing or invalid denominator flagged, no deduction calculated, only that employee's finalization blocked while the others finalize (L32, per the approved R7.0 design)); pending / rejected leave ignored; parity spec for employees without absence or leave; D5 (b) absence specs (salary change inside the period, a period crossing two months, no 26 divisor) and the Parity Report; same-date absence and unpaid leave deducted once; termination payout line (D6); recalculation of an under-review period; blocker specs with exact missing dates; D9 deadline: legacy undefined days warn before it and block after it; D11 setting on and off for the absence denominator; D12 partly unscheduled period; D13 payout rate; D15: joiner, leaver, partly unscheduled period and a salary change inside a partial window, each for absence, unpaid leave and payout, asserting the same dates in numerator and denominator, the worked example of §12, and equality with the D5 (b) / L28 formula for a fully eligible period; OT1 leaver with no scheduled day flagged; D16: a central employee's unpaid leave deducted by Calendar-day Proration (formula per the OT4–OT8 decisions), no assignment or schedule written, no division by zero, absence untouched; a scheduled employee's result unchanged by D16; D17: required employees with no assignment, a legacy assignment without working days, Not Reviewed or exception-list status never priced by D16 (C, L32, warnings unchanged); D18: a central leaver's settlement held, no payout line, no forfeiture or expiry entry, balance and history unchanged, review case audited; D19 / D20: held under a `Forfeit` setting too, and no payout computed before a calculation is formally approved |
| R8 | Expense and recurring-template validation specs; immutability spec on approved allocations |
| R9 | Rule/version/link model and service specs; permission and dependency specs; cross-business specs |
| R10 | Contract boundary spec with a probe provider; `allocation_blockers` refusal; snapshot write/void; insurance split equals salary percentages; idempotency of re-finalization; cross-business payload specs |
| R11 | Report specs: snapshot vs pre-switch months; provisional labelling; aggregate privacy for branch-scoped viewers; CSV parity |
| All | `spec/architecture`, RuboCop, Zeitwerk, focused regression; full suite only with owner approval |

## 16. Risks, rollback and operational safeguards

| Risk | Safeguard |
|---|---|
| Payroll blocked on payday by new gates (C, K) | Warnings from submit-for-review; R0 data clean-up; gates enabled only after a clean read-only preview of the next period |
| Enforcement breaks current scheduling | R0 lists not-required candidates with active assignments; HR ends them first; enforcement after the deadline (D1 (1)) |
| History drift in reports | Snapshot-first; pre-switch months use the unchanged legacy computation |
| Interim Unallocated rows (#114 already on `main`) | Avoid creating floating assignments in production until R10, or accept them as historical (H) |
| Contract misuse / upward dependency | Boundary specs (R3 invariant check contract, R10 finalization contract) |
| Write-skew between the salary and requirement services | Shared per-employee advisory lock, taken first in both transactions (L3); concurrency spec |
| Paths outside the services (console `SalaryProfile.create!`, seeds, a future import) bypass the invariant | Boundary spec: no salary-profile or requirement-history writes outside the owning services; seeds moved to the service; R3b periodic detection records any resulting conflict as a Historical Violation |
| Backfill creates or reveals conflicts | L12 date precedence; post-backfill detection records Historical Violations (L17); no locked period touched (L5) |
| Many employees land on the HR exception list (missing `hire_date`, §3.6) | R0 read-only count of employees without `hire_date` or reliable records before the backfill; HR clears the list before enforcement (D1 (1), L25) |
| Employee creation flows break when the selection and start date become mandatory | Both creation paths (admin form, data-request approval) changed together in R3 with request specs (L18) |
| Rejected-attempt entry lost with the rollback, or the audit write fails | Written in a separate transaction after the rollback; durable record + background retry + administrator alert; structured-log fallback if the record itself cannot be written (L14, L20) |
| No administrator alert channel exists today (§3.6) | L29 / L34 set the dashboards; built in R3 on the durable record (§6.8); `Rails.error.report` stays on every failure |
| Cross-business leakage of audit-failure notifications (the legacy `notifications` table has no `business_id`) | Legacy table not used; `business_id` NOT NULL on the durable record; database-level `policy_scope`; cross-business request specs; UI filtering never the control (L34) |
| No platform-level System Administrator identity exists (§3.6) | D1 sets the meaning (the WorkPulse platform operations team); the G1 identity design is approved as an architecture change before the system-wide dashboard and Retry Now are built; never grant cross-business access through `PermissionRole` or `require_admin_access!` |
| Leave approved for already-paid dates silently changes payroll | Only approved leave is read, and locked periods are never changed automatically; post-lock approvals are flagged for review (L5, L17, L21) |
| R7 blocked waiting on leave | R6b's rules are approved (L31, L33); Q44 and Q45 (d) are decided (D8 (a), (b)) and the other Q45 points are **[T]**; R7 can ship absence without the leave step only with an explicit owner decision |
| Leave balance drift or rounding loss | Append-only ledger, two decimals stored, display rounding only, no writable balance column (L26) |
| Leave cancelled after its days were paid | Locked period never modified; HR/Payroll review and separate audited correction (L27) |
| Per-employee finalization block (L32) has no mechanism; finalization is per period (§3.6) | D7 approves the principle only; the R7.0 design is approved before R7; until then the unpaid-leave deduction is not shipped. Narrow interaction with L9 (1): a monthly employee on a legacy assignment without weekdays who takes approved unpaid leave is blocked under L32 even though absence-only legacy cases still finalize under L9 (1) — both rules applied as approved |
| One person executes and approves a correction | Default refusal by identity in the service (owners included), opt-in exception audited (L35) |
| Owners hold both correction permissions implicitly | L35 enforced by identity and designation, not by permission checks (§6.9) |
| Double approval or a fallback approval racing an approver being added | Business approver-pool lock + correction row lock, status re-checked (L35) |
| Removing the last Finance Approver stalls corrections | Pending corrections route to Super Admin automatically (L35) |
| Leave ledger grows complex (batches, FEFO, splits) | One WF ledger service, property specs for Σ ≥ 0 and batch conservation (L31) |
| Monthly absence deductions change for every monthly-paid employee (D5 (b) replaces today's ÷ `working_days_per_month`) | Parity Report reviewed before rollout; the change communicated; absence and unpaid leave share one divisor and one holiday setting (D11) and a date is never deducted twice |
| Plan baseline drift: `origin/main` moved to `3e01ac3` (PRs #116 and #117) and changed `Payroll::Approver`, `Payroll::Reopener` and the schema | Re-read every §3 evidence row on the new baseline and build from a fresh branch off `main`, not from `feat/floating-employees` (already merged as #114) (§18.4) |
| Retry enqueue not atomic with the durable record in production (separate `queue` connection) | Durable record is the source of truth; sweeper re-enqueues due records; delivery idempotent under a row lock (§18.2 G10) |
| Per-employee finalization block collides with the one-active-insurance-expense-per-period unique index | Supplementary entry-level expense with its own unique index; the period's original expense is never edited (§18.2 G4) |
| D7 read as authorisation to implement employee-level holds | R7.0 is a separate design approval; R7 and R10 do not start without it (§18.6.3) |
| The cross-branch overlap rule (D5 (a)) blocks schedule changes for employees with legacy overlaps | R4's report lists existing overlaps; HR ends one before changing the schedule; history never reinterpreted |
| Legacy assignments without working days still exist when the D9 deadline passes, so finalization blocks (C) | R4's missing-schedule report from deployment, with the deadline shown; warnings from submit-for-review; gates enabled only after a clean read-only preview of the next period |
| A deadline passes before the phase that enforces it is deployed (R5 for D1 (1); R7, which waits for R7.0, for D9) | The deadlines are not moved. **[T]** Enforcement starts when the enforcing phase is deployed: R5 refuses new assignments from then on; R7 applies the D9 end from the first Payroll Period it calculates, after the read-only preview above (§18.7.2 K26) |
| Partly scheduled or partly employed periods are priced at a distorted rate | D15 fixes the principle; property specs check that numerator and denominator cover the same dates and that deductions never exceed the attributed salary; the Parity Report includes joiners, leavers and legacy-mixed periods |
| Calendar-day Proration (D16) is applied to employees who have a schedule, or hides a missing schedule of a required employee | D17: D16 applies only when the requirement in force is not required; required, Not Reviewed and exception-list employees keep C, D12 and L32; specs pin both prorations separately |
| A held settlement (D18) is forgotten, silently paid, or eroded by expiry | Pending review cases listed on the HR/Payroll review report; no ledger entry while pending; expiry and forfeiture jobs skip held balances; resolution audited (OT9) |
| A held balance is forfeited or paid before every D20 condition is met, or `Forfeit` is converted into `Pay Out` at release | The release service checks each D20 condition in its transaction and records the setting applied (D19); one spec per missing condition; only a formally approved calculation can price a payout (D20 (1)) |
| The D16 formula details (OT4–OT8) are settled in a way that creates a business rule | Each OT4–OT8 resolution is reviewed against D16 and L28 (actual days, never a fixed 30); anything beyond them returns to the owner |
| The D15 segment handling (OT2) is implemented in a way that changes fully eligible periods with a mid-period salary change | OT2's recommended reading reproduces D5 (b) / L28 exactly for fully eligible periods; a spec pins that equality; any other reading goes to the owner |
| A platform-operator path leaks cross-business data | A separate identity and namespace, read-only apart from Retry Now, with cross-business and negative specs (§18.2 G1) |
| Rollback | Every migration is additive → code-only rollback; snapshots are voidable, never deleted; the old column is dropped only in R13 |
| Device-branch data quality | Not an allocation driver (J); BUG-044 tracked separately |

## 17. Out of scope

* Actual-worked-branch allocation for floating employees (J); BUG-044.
* A recurring-pattern / rota engine (A8).
* Holiday premium pay; overtime rule changes.
* Mobile check-in for floating employees (Q14).
* Automatic redistribution or correction of historical Unallocated / Unattributed records (H).
* Changes to PR #110 behaviour or its branch (A11).
* Salary-advance phases beyond reading the new scheduled days.
* Any production data change; every production step in this plan is read-only.
* Automatic resolution of invariant conflicts, and any automatic Daily → Monthly conversion workflow (L2, L7).
* The compensating-entry mechanics of financial corrections for Historical Violations in locked periods (L17) — R3b
  covers detection, records, the review report, the L30 permissions and the L35 request, approval, rejection and
  resubmission workflow; how a
  correction is posted needs its own design and approval.
* Branch-specific holiday calendars (D3).
* Creating a `ShiftAssignment` or schedule for an employee only to calculate unpaid leave (D16, D17).
* A payout calculation for leavers without attendance requirement and schedule. Its formal approval is a release
  condition (D20 (1)); until then their settlement is held (D18, D19).
* Implementing employee-level finalization holds before the R7.0 design is approved (D7 approves the principle only).
* Manual retry for Business-level users (L34: System Administrator only in the first implementation).
* Any change to or reuse of the legacy `notifications` table (§6.8).
* Email alerts for audit failures (L29 allows them later as a secondary channel).
* Branch- or employee-specific leave policies (L22 keeps the design extensible only).
* Leave in Finance & Sales (L15).

---

## 18. Architecture review (revision 7)

Scope: L1–L35, Q3–Q14, Q39–Q45, R0–R13, the six domains and module boundaries. Evidence read at the working-tree
baseline (`ec1ecd2`). Where `origin/main` (`3e01ac3`) differs, that is stated; it was read without fetching. Labels:
**[A]** approved, **[C]** current code, **[T]** technical decision recommended here, **[Q]** open question; D1–D8 were
owner decisions pending at revision 7 (approved in revision 8; D9–D14 in revision 9).

### 18.1 Classification of every open question

Class **A** = business decision (owner only) · **B** = technical decision (decided here **[T]**) · **C** = mixed (business
part to the owner, technical part decided here).

| ID | Class | Business part → owner (§18.5) | Technical decision **[T]** | Blocks |
|---|---|---|---|---|
| Q3 | A | Two dates: end of HR review, and end of the L9 (1) legacy-schedule exception → **D1** (review deadline), **D9** (legacy end) | Two separate business-level dates, each with its own effect (revision 9 replaces "after the later date", §18.7.2 K15): the Not Reviewed deadline gates R5's enforcement; the D9 date ends L9 (1) in R7's finalization blockers | — (decided: D1, D9, D10) |
| Q4 | C | Do any branches observe holidays the others do not? → **D3** | Workforce owns the Holiday Calendar (scheduling data; AP reads it through the allowed AP → WF edge); permission `manage_holidays` in the `shifts` group, business-level, audited; no `branch_id` column (D3: business-wide only) | — (decided, D3) |
| Q5 | B | — (C and L31 already need an end date) | WF-stewarded `users.employment_ended_on`. HR enters it in a WF service, which then deactivates through `OrganizationAccess::Accounts.toggle_active!` (WF → OA allowed, D1 of module-boundaries). It is mandatory when an employee with payroll history is deactivated. Payroll, proration and settlement read it | R6b leaver proration; R7 |
| Q6 | B | — | Keep "last state decides the whole period" (the approved attribution rule, §4.2) | — |
| Q7 | B | — | The rule version in force on the period's last day | — |
| Q8 | B | — | As proposed: re-resolve by date; no version may start inside a finalized or paid period; audited | — |
| Q9 | A | Which payroll states block backdating a requirement change → **D4** | Implemented as one predicate `PayrollPeriod#blocks_requirement_backdating?`, so the answer is a one-line change | R3 backdating rule |
| Q10 | C | May one employee hold regular schedules at two branches at the same time? → **D5** | D5 (a) = no: a `ShiftAssignment` validation refusing new overlapping regular assignments across branches; existing overlaps kept and reported; the resolver is unchanged | R4 validation (decided) |
| Q11 | A | Price of an absent day for monthly-paid employees → **D5** | One `Payroll::DailyRate` object used by absence and by L28 (aligned by D5 (b) and D11), so the choice is configuration, not two code paths | R7 |
| Q12 | A | Label and grouping of the central and floating aggregate → **D2** (non-blocking) | One i18n key and one Reporting group | R11 labels only |
| Q13 | B | — | As proposed: `manage_cost_allocations` in `expense_administration`, branch-scopable via `BranchScope`, depending on `view_expenses` and `view_employees`, not in presets | — |
| Q14 | B | — | Out of scope; biometric remains the floating channel (A11, PR #110 untouched) | — |
| Q39 | A | Termination payout amount and payroll treatment → **D6** | Ledger entry `termination_settlement` with the D6 amount; AP pays it as a separate Final Payroll line; never silently paid or forfeited | R7 payout (decided; rate D13) |
| Q40 | C | Is a held employee finalized and paid late **within the same period**, with the cost shown Provisional until released? → **D7** | The entry-level finalization hold, §18.2 G4 | R7, R10 |
| Q41 | A | Resubmission limit → **D8** (recommend none) | Linked chain `resubmission_of_id`; no counter needed | — (non-blocking) |
| Q42 | C | (a) System Administrator = the WorkPulse operator team, never a business user; (b) Super Admin = the business owner → **D1** | (a) platform-operator identity, §18.2 G1; (c) the Business-level responsible person = explicit permission `monitor_audit_failures` (OA, business-level, never in presets) | R3.5 |
| Q43 | B | — (L35 already names HR and Finance Manager) | Add role presets `hr` and `finance_manager` to `ROLE_TYPES` / `DEFAULT_PERMISSIONS_BY_ROLE_TYPE`. Presets fill permissions only when a role is created with none chosen (`permission_role.rb:381-384`), so existing roles are unchanged. Approver-management permission: `manage_historical_correction_approvers` | R3b |
| Q44 | A | May any paid leave type apply to daily-paid employees? (L6 says unpaid only; local labour-law check advised) → **D8** | The `leave_types.payroll_effect` check reads the employee's salary type on each date; changing L6 later is a data change, not a redesign | — (L6 stands) |
| Q45 (a)(b)(c)(e)(f)(g)(h) | B | — | As the Q45 recommendations, now **[T]**: (a) available = accrued, unexpired on every requested date, minus approved untaken leave; (b) calendar days ÷ days in that leave year, 2 dp; (c) accrual periods start at the anniversary; (e) partly locked = affected; (f) prospective, with an optional audited HR adjustment entry so nobody loses accrued rights; (g) default fallback chain area manager → HR → business owner, configurable, never auto-approval; (h) activation by a different user from the definer | — |
| Q45 (d) | A | Confirm the literal reading: a carry-over made shortly before 31 March expires on that 31 March → **D8** | Superseded by D8 (b): expiry on 31 March of the year after the carry-over year (D14) | — (decided) |

**Revision 8 status:** every A row and the business part of every C row is decided by D1–D8 (§2 M), except the
L9 (1) end date in Q3. Q46 (§5) collects the interpretation points those decisions leave open. The **[T]** column
is unchanged; it is engineering-reviewable and needs no owner decision.

**Revision 9 status:** the L9 (1) end in Q3 is decided by D9, and Q46 by D10–D14 (§2 N). No class A or C question
is open. Q47 (§5) is new; the Q3 **[T]** cell is corrected (§18.7.2 K15).

### 18.2 Architecture gaps

Each gap: evidence **[C]** · problem · design **[T]** · domains · dependencies and migration risks · tests and
acceptance.

**G1 — System Administrator versus Business Super Admin** *(revision 14: full design in §19.5)*

| | |
|---|---|
| Evidence | Every user belongs to one business (`validates :business, presence: true`, `app/models/user.rb:128`); owner = `business.owner_id == id` (`:213`); `can?` returns true for owners (`:260-261`); "Super Admin" in code comments = business owner (`app/policies/till_deposit_policy.rb:7`); the admin namespace admits 13 ordinary permissions (`app/controllers/admin/base_controller.rb:7-18`); `audit_logs.actor_id` and `business_id` are NOT NULL |
| Problem | L34 needs a cross-business operator. Modelling one as a `User` or a permission would either be impossible (a business is mandatory) or let a business role grant cross-tenant access, breaking module-boundaries §18 rule 12 |
| Design **[T]** | A separate OA-owned identity, e.g. `PlatformOperator` (own table and Devise model, own `/platform` namespace and base controller, no `business_id`, no `PermissionRole`, granted and revoked only by console task with audit). Its powers: read every business's audit-failure events, and **Retry Now**. Nothing else in the first implementation. The delivered audit entry keeps its original business actor; the operator is recorded in the attempt log (G10). Super Admin (L35) stays the business owner inside the business |
| Domains | OA (identity, access); Infrastructure (dashboard); module-boundaries §16 and §18 updated |
| Dependencies / risks | D1 decided (revision 8); the design itself still needs approval as an architecture change (R3.5); a second Devise scope (sessions, CSRF, lockout, a strong-authentication recommendation); security review (Brakeman, policy specs). Additive table only |
| Tests / acceptance | Operator cannot use business pages and business users (owners included) get 404 on `/platform`; operator sees events of all businesses; only operator can Retry Now; boundary spec: unscoped event queries appear only under `/platform` |

**G2 — Platform-wide versus Business-level permissions and notification isolation**

| | |
|---|---|
| Evidence | `notifications` is per user with no `business_id` (`db/schema.rb:967`), classified Legacy / unused and "never a business domain" (module-boundaries §16, `:366`, `:687`); permissions are business-scoped through `PermissionRole` |
| Problem | L34 needs one notification per event, two dashboards, and isolation that does not depend on the UI |
| Design **[T]** | As §6.8: the durable record is the notification (`business_id` NOT NULL). The business dashboard uses `policy_scope` with a database-level `business_id` filter and `policy_scope(...).find`. The platform dashboard is only in the `/platform` namespace (G1). Business access needs `monitor_audit_failures`; owners get it implicitly, for their own business only. The legacy table is untouched |
| Domains | Infrastructure; OA (permission) |
| Dependencies / risks | G1 for the platform side; the business side is independent and can ship first |
| Tests / acceptance | Cross-business id → not found; policy-scope specs; no view or controller filters by business in Ruby after loading |

**G3 — Historical correction approval and separation of duties**

| | |
|---|---|
| Evidence | `Approvals::SelfApproval.by_requester?` (`app/services/approvals/self_approval.rb`) states it and `Payroll::AdjustmentApproval` are "deliberately the only two places" for creator ≠ approver, and `AdjustmentApproval` has a **business-owner exception**; owners hold every permission implicitly |
| Problem | Copying the adjustment pattern would let an owner approve their own correction and bypass designated Finance Approvers, which L35 forbids |
| Design **[T]** | The approval rule is enforced by identity and designation, not by `can?`. The correction approver service calls `Approvals::SelfApproval.by_requester?`; there is no third copy of the rule. The opt-in setting (`allow_same_person_correction_approval`) wraps that call. There is **no owner exception**: an owner approves only as a designated Finance Approver or through the empty-pool fallback with a reason. Locks: business approver-pool advisory lock, then the correction row `FOR UPDATE`, with status re-checked (§6.9). Update the `SelfApproval` header comment to name the new caller |
| Domains | AP (corrections); OA (permissions, designations, setting) |
| Dependencies / risks | Q43 presets; the posting mechanics of corrections stay out of scope (§17) |
| Tests / acceptance | §15 R3b list; plus an owner holding both permissions is refused without the opt-in; concurrency spec (two threads) → exactly one approval |

**G4 — Employee-level payroll finalization holds (L32)** *(revision 14: superseded by the R7.0 design, §19.4)*

| | |
|---|---|
| Evidence | Finalization is period-level: one `@period.update!(status: "finalized")` after period-wide refusals (`app/services/payroll/approver.rb:39-103`); entry statuses `draft` / `approved` / `disputed` (`app/models/payroll_entry.rb:11`); `Payroll::FinalizationEffects#period_finalized` passes period-level insurance totals; Finance allows **one active insurance expense per period** (unique index `idx_expenses_on_active_source_payroll_period` on `(source_payroll_period_id, unallocated)`); `Payroll::CentralReview` fingerprints the floating entries. **Precedent on `origin/main`** (PR #117, not in this baseline): Salary Payment Hold withholds individual entries at **payment** while "the period is still paid for everyone else" (`salary_payment_holds`, `salary_payment_withholdings`, one live withholding per entry, `Payroll::ReleasedSalaryPayer`) |
| Problem | L32 needs every other employee finalized while one is not. Today finalization freezes all entries, the period has one insurance expense, and every downstream effect is period-wide |
| Design **[T]** | (1) `payroll_entry_finalization_holds` (AP): `business_id`, `payroll_entry_id`, `reason_key`, `created_at`, `released_at`, `released_by_id`, `finalized_at`; one live hold per entry (partial unique index, the #117 pattern). Set automatically when R7 flags the entry; never deleted. (2) Period finalization finalizes everyone except held entries; `period_finalized`'s per-employee payload (K) excludes them; the period page shows "N held". (3) A held entry stays recalculable while the period is finalized, an exception confined to one predicate, e.g. `PayrollEntry#frozen?` = period locked and no live hold. (4) Release: after the data is fixed, recalculate that entry, have it reviewed, then `Payroll::HeldEntryFinalizer` runs under the period lock and calls a new contract operation `entry_finalized(period:, entry_id:, actor:, costs:)`. Finance writes a **supplementary** insurance expense with a new nullable `source_payroll_entry_id` and its own partial unique index, plus allocation snapshot rows. The period's original expense is never edited (H, append-only). (5) Payment: held entries are excluded from period payment; a released entry is paid through the #117 released-salary path. (6) Reopen voids supplementary expenses with the period's |
| Domains | AP (lifecycle, contract); FS (supplementary expense, snapshots); Reporting (held = Provisional, F) |
| Dependencies / risks | D7 (principle approved in revision 8; this design needs separate approval in R7.0, §18.6.3); rebase onto `3e01ac3` (#117 changed `Approver` and `Reopener`); the contract is extended **once**, in R10, with K's per-employee payload and `entry_finalized`; `CentralReview` fingerprint must exclude held entries consistently; an additive expense column and index migration. This is the largest lifecycle change in the plan, so it gets its own approved design phase (R7.0) |
| Tests / acceptance | A period with one held entry: the others frozen and in the payload, the held one excluded from insurance and snapshots; the held entry editable while the others are not; release finalizes once (two threads → one); the supplementary expense is unique per entry; reopen and paid interactions; interaction with #117 withholding; contract probe spec; **parity: periods without holds produce identical results to today** |

**G5 — Existing role and permission architecture**

| | |
|---|---|
| Evidence | `PermissionRole` = permission array plus per-permission scopes; `PERMISSION_GROUPS`, `SCOPABLE_PERMISSIONS`, `BRANCH_SCOPABLE_PERMISSIONS`, `PERMISSION_DEPENDENCIES`; archetypes `branch_manager` / `area_manager` / `accountant` / `employee` preset permissions only at creation (`app/models/organization_access/permission_role.rb:5`, `:118`, `:381-384`); owners implicit |
| Problem | The plan adds several permissions with different scope semantics and needs HR / Finance Manager defaults that have no archetype |
| Design **[T]** | New permissions: `manage_historical_payroll_corrections`, `approve_historical_payroll_corrections`, `manage_historical_correction_approvers` (payroll group, business-level, not scopable, each depending on `view_payroll`; the approvers one also on `manage_employees`); `monitor_audit_failures` (business-level); `approve_leave_requests` (identifies HR leave approvers, `EmployeeScope`); `manage_leave_settings` (types, policy, routing; activation by a different user, Q45 (h)); `manage_holidays`; `manage_cost_allocations` (Q13). Presets `hr` and `finance_manager` added (Q43). No ordinary payroll permission implies the new ones |
| Domains | OA |
| Dependencies / risks | Each permission lands with its feature phase; dependency and preset specs; no backfill (new permissions are granted explicitly) |
| Tests / acceptance | Dependency specs; presets fill only empty new roles; neither correction permission implies the other; owner identity rules (G3) |

**G6 — Leave balance, accrual, carry-over and termination settlement**

| | |
|---|---|
| Evidence | No leave concept exists (§3.6); `EmployeeRequest` is WF-owned; `hire_date` is mass-assigned without audit (`app/policies/user_policy.rb:12-15`); there is no employment end date |
| Problem | L31 needs an exact, auditable, never-negative ledger with batches, FEFO, splits, anniversary years and jobs that run on business days |
| Design **[T]** | §6.7 and §8 tables; one WF service as the ledger's only writer. Every balance-changing operation (approval, cancellation, accrual, carry-over, expiry, settlement) takes a per-employee **leave** advisory lock, a namespace different from the L3 invariant lock; if both are needed, the invariant lock first. Accrual, carry-over and expiry run in an idempotent daily recurring job (`config/recurring.yml`), using `BusinessDay.current(context: business)`, never `Date.current`, with natural unique keys (user, kind, period start or batch). Service-date correction is prospective, with an optional audited adjustment entry (Q45 (f)). Termination reads `employment_ended_on` (Q5) for the final proration and writes the settlement entry per the business setting; the amount follows D6 and D13 |
| Domains | WF (ledger, policy, types, routing, jobs); AP reads approved leave and settlement entries; OA branch data for routing |
| Dependencies / risks | Q5 **[T]** column first; D6 decided (rate D13 over the eligible dates of D15); D8 (a) and (b) decided (year: D14). Additive tables only |
| Tests / acceptance | Property specs: Σ ≥ 0 and batch conservation; idempotent jobs re-run; business-day rollover at `business_day_start_hour`; concurrent approval and accrual; FEFO across batches; expiry on each batch's own 31 March |

**G7 — Notification ownership and module boundaries**

| | |
|---|---|
| Evidence | module-boundaries §16: Audit = `AuditLog` / `AuditLoggable` (Infrastructure); "Notifications: none active (legacy table, §20); future infrastructure, never a business domain". The dependency gate fails on any **unmapped table or `app/` file** (`spec/architecture/dependency_inventory_spec.rb`) |
| Problem | New infrastructure tables and the platform namespace must be mapped in the same change, or CI fails |
| Design **[T]** | `pending_audit_events`, `pending_audit_event_attempts`, the dashboards and the platform namespace are mapped as **Infrastructure (Audit)** in module-boundaries §10–§11 and §16 in the same commit as their migration. `platform_operators` is mapped to OA. The legacy `notifications` row stays as it is. Mapping these owners is not a new D4 exception; any cross-domain read the dashboards need (employee names) uses the allowed Infrastructure read path or the existing OA accounts read — to be classified in the gate when written |
| Domains | Infrastructure, OA; docs |
| Dependencies / risks | The gate; regenerating the dependency report needs approval when mappings change (flag it as stale) |
| Tests / acceptance | `spec/architecture` green; dependency inventory 0 unmapped / 0 unclassified |

**G8 — Payroll-to-Finance integration** *(revision 14: the single extension happens in R10, before R7, §19.10)*

| | |
|---|---|
| Evidence | `Payroll::FinalizationEffects` operations `period_finalized` (insurance total, by branch, unallocated) and `period_reopened`; synchronous, inside the transaction, registered at boot (`app/services/payroll/finalization_effects.rb`); Finance creates the insurance expense already approved |
| Problem | K (per-employee costs and allocation blockers) and G4 (entry-level finalization) both change the contract; doing them separately would change it twice and leave a mixed payload |
| Design **[T]** | Extend the contract once in R10: `allocation_blockers(period:, costs:)`, `period_finalized(period:, actor:, costs:)` (costs exclude held entries), `entry_finalized(period:, entry_id:, actor:, costs:)` and `period_reopened` (voids the period's and its supplementary expenses and snapshots). Payroll builds the payload; Finance never reads payroll entries (existing boundary rule). The registration check (`OPERATIONS`) and the Finance implementation change in the same commit |
| Domains | AP (defines), FS (implements) |
| Dependencies / risks | R7 (G4 hold) and R9 (rules) first; the unique-index migration for supplementary expenses; the transition from today's Unallocated writes (X6, H) |
| Tests / acceptance | Contract probe spec; Σ payload = Σ entry costs; reopen voids all; no new `unallocated: true` expense; the Finance-reads-no-payroll boundary spec still green |

**G9 — Effective-dated employee attendance requirements**

| | |
|---|---|
| Evidence | Nothing exists (§3.6); the only reader of the old flag is `Shifts::AssignmentEligibility`; `ShiftAssignment.current` uses `Date.current` (`app/models/shift_assignment.rb:65`) — the same mechanism as BUG-043 (`docs/quality/deferred-bugs.md`) |
| Problem | "Today" for the cache, backdating checks and assignment validation must be the **business day**; future-dated rows must take effect without drift |
| Design **[T]** | Every requirement date check uses `BusinessDay.current(context: business)`. The cache is written in the history row's transaction for rows effective on or before the business day, plus an idempotent daily roll-forward job per business. The checks never read the cache (L4). History is append-only: no update path in the service and a model guard that refuses updates. `ShiftAssignment.current`'s server date is **not** fixed inside this work; it is noted against BUG-043's mechanism for the register's owner to decide (deferred-bug policy) |
| Domains | WF (history, cache, job); AP reads via the WF read API |
| Dependencies / risks | D4 decided: the predicate is `under_review` or later; the backfill (R3.3) needs R0's counts |
| Tests / acceptance | Business-day rollover specs; the roll-forward job is idempotent; the model refuses updates; a cache-versus-history consistency spec |

**G10 — Audit failure recovery and retry concurrency**

| | |
|---|---|
| Evidence | `log_audit` uses a `requires_new` savepoint and reports failures through `Rails.error.report`; `audit_logs` has no idempotency column; Solid Queue 1.4.0 (`Gemfile.lock`) supports `limits_concurrency`; **production queue writes use a separate connection** (`config/environments/production.rb:53`; one physical database, `config/database.yml`), while development runs on the primary connection |
| Problem | Enqueue is not atomic with the durable record in production; retries from the job and Retry Now can race; delivery must happen exactly once without changing `audit_logs` |
| Design **[T]** | The durable record is the source of truth; the job is enqueued after commit. A recurring **sweeper** (`config/recurring.yml`, e.g. every 5 minutes) enqueues records with `next_attempt_at <= now` and no resolution, so a lost enqueue only delays delivery. Each attempt (job or Retry Now) runs one service: lock the record `FOR UPDATE NOWAIT` (busy → job skips, Retry Now shows "retry in progress"); if resolved, stop; insert the `AuditLog` row and set `resolved_at` / `audit_log_id` **in the same transaction**, which gives exactly-once delivery with no `audit_logs` schema change. `limits_concurrency` per event id is an optimisation, never the guarantee. Backoff 1 min, 5 min, 15 min, then hourly; escalation when `consecutive_failures` reaches 3; the attempt log row is written in a separate transaction so a failed attempt is still recorded |
| Domains | Infrastructure |
| Dependencies / risks | Specs must not rely on the development single-connection behaviour; job registration needs a Solid Queue supervisor restart |
| Tests / acceptance | Forced failure → record kept, sweeper re-enqueues; two concurrent attempts → one delivery; Retry Now during a job → refused cleanly; escalation exactly at the third failure; resolved records kept; a production-like spec with the queue on a separate connection, or a spec that never assumes enqueue atomicity |
| Revision 17 | The attempt-log row is written in its own transaction after the delivery transaction ends, as in the design row above; the §6.8 diagram, which appends it inside the locked transaction, is superseded on this point (§19.13 T-R31-1) |
| Revision 17 (hardening) | A failure of the whole delivery transaction is recorded in an independent transaction, counters and attempt row together (D33, T-R31-12). Each retry is enqueued at its exact time; the sweeper only recovers lost jobs, through dispatch claims (T-R31-13). A receipt keyed by the entry's `entry_key` makes a second Audit Log entry impossible in the database (T-R31-11) |

### 18.3 Technical decisions adopted **[T]** (summary)

| # | Decision | Rationale |
|---|---|---|
| T1 | Platform-operator identity separate from `User` and `PermissionRole` (G1) | The only way to keep tenant isolation absolute; additive |
| T2 | Durable record = notification; legacy `notifications` untouched (G2, G7) | Structural de-duplication; no change to a table classified Legacy |
| T3 | Corrections enforced by identity and designation, no owner exception, `SelfApproval` reused (G3) | Owners hold every permission implicitly |
| T4 | Entry-level finalization hold, supplementary expense per entry, one contract extension in R10 (G4, G8) | Satisfies L32 without editing a finalized period's records; reuses the #117 pattern |
| T5 | New permissions and the `hr` / `finance_manager` presets (G5, Q43) | Presets touch only new roles |
| T6 | One WF leave ledger writer, a leave lock, idempotent business-day jobs (G6) | Exactness and auditability (L26, L31) |
| T7 | Infrastructure mapping in the same commit as each new table (G7) | The dependency gate requires it |
| T8 | Business-day dates, append-only history, roll-forward job (G9) | CLAUDE.md business-day rule |
| T9 | Sweeper, row-locked exactly-once delivery, no reliance on atomic enqueue (G10) | Production uses a separate queue connection |
| T10 | Q5 end-date column; Q6–Q8, Q13, Q14 and Q45 technical parts as listed in §18.1 | Already consistent with approved rules |

### 18.4 Implementation readiness (R0–R13; updated in revisions 8 to 13)

*(Superseded by revision 14: readiness, order and approval gates are in §19.10–§19.12.)*

Prerequisite for every implementation phase: **re-baseline**. Branch from current `main` (`3e01ac3` or later), not
from `feat/floating-employees` (merged as #114), and re-read the §3 evidence rows that #116 and #117 changed. This
plan should be committed to a docs branch off `main` first — that is the owner's choice and has not been done.

| Phase | Status | Exact blockers | Notes |
|---|---|---|---|
| R0 read-only queries | **Ready** | an authorised operator | Run before R3.3 |
| R1 documentation | **Ready** after the owner approves this plan | owner approval | `CLAUDE.md` rules only for behaviour being implemented |
| R2 `MoneySplitter` | **Ready** | — | Behaviour-preserving; independent |
| R3.1 durable audit record, sweeper, attempt log, business dashboard (L20, L29, L34 business side, G2, G10) | **Ready** | — | Build first: R3.4's rejected attempts depend on it |
| R3.2 requirement history, change service, cache, creation with mandatory selection and start date, service-date correction (L4, L10, L18, L31) | **Ready** | — | Backdating refused once an affected period is Under Review or later (D4) |
| R3.3 backfill and HR exception list (L11, L12, L19, L25) | **Blocked** | R0 counts reviewed; R3.2 | — |
| R3.4 daily-paid invariant, both directions (L1–L3, L13) | **Ready after R3.1 and R3.2** | — | — |
| R3.5 platform operator, system-wide dashboard, Retry Now (G1) | **Ready after R3.1** | approval of the G1 identity design as an architecture change (module-boundaries §18) | D1 decided: System Administrator = the platform operations team, kept separate from owner permissions; additive |
| R3b Historical Violations and corrections (L17, L24, L30, L35) | **Ready after R3.4** | — (Q43 decided **[T]**; D8 non-blocking) | Posting mechanics stay out of scope (§17) |
| R4 `working_weekdays`, `ScheduleChanger`, templates, cross-branch overlap validation | **Ready** | — | D5 (a): new regular assignments may not overlap across branches; existing overlaps reported, not reinterpreted. Its production deployment starts the D9 count, so the missing-schedule report ships with it |
| R5 assignment enforcement in every path | **Ready after R3.2 and R4** | — | Not-reviewed cut-off = end of the second complete Payroll Period after R3.3 is deployed (D1 (1), D10) |
| R6 Holiday Calendar | **Ready** | — | Business-wide only; no branch-specific calendars in this phase (D3) |
| R6b leave management | **Ready after R3.2** (service date) and the Q5 column | — | Daily-paid unpaid only (D8 (a)); expiry on 31 March of the calendar year after the carry-over year (D8 (b), D14); the settlement entry records the D6 payout, which AP pays in R7; held settlements (D18) and their D20 review steps, released only after D20 (1) |
| R7.0 finalization-hold design (G4) | **Ready to design** | separate owner and architecture approval of the design document | D7 approves the business principle only, not the design and not R7; required content in §18.6.3; no code |
| R7 scheduled days, absence (D5 (b)), leave effects, L28 deduction, L32 hold, D6 payout | **Blocked** | R4, R5, R6, R6b, the approved R7.0 design, the Q5 column; OT1–OT9 settled in the design review | D5, D9, D11–D13 and D15–D27 decided; OT1 decided as D22, details D24–D27; Parity Report reviewed before rollout; resolver unchanged (D5 (a)); legacy undefined days stop being exempt at the D9 deadline |
| R8 expense validation | **Ready** | R2 | — |
| R9 Cost Allocation Rules | **Ready after R2** | — | — |
| R10 contract extension | **Blocked** | R7, R9, R7.0 | The contract is changed once (G8) |
| R11 reports | **Blocked** | R10 | Label decided: D2 |
| R12 / R13 old-flag removal | **Blocked** | R5 deployed and verified / R12 deployed and verified | — |

**Recommended order:** R0 → R1 → R2 → R3.1 → R3.2 → R3.4 → R3.3 → R3b → R4 → R5 → R6 → R6b → (R7.0 approved) → R7 → R8 →
R9 → R10 → R11 → R12 → R13. R8 and R9 can run in parallel with the R3–R6 track. Reordering versus §13: R3 split, with
the audit infrastructure first; Q10 moved from R4 to R7; a new R7.0 design gate before R7 and R10.

### 18.5 Owner decisions requested in revision 7

**All eight were approved in revision 8** and are recorded as rules in §2 M. This table keeps the revision 7
request and recommendation for traceability. D8 (b) was approved with wording that differs from the (b)
recommendation below; see §18.6.2 K1. The second date in the D1 (a) recommendation was approved in revision 9 as
D9, and its reference point as D10 (R3.3). Only business decisions were asked; every technical point is decided in
§18.1–§18.3.

| # | Decision | Recommended | Consequence | Blocks implementation? |
|---|---|---|---|---|
| D1 | **Transition and operator identities:** (a) the HR review deadline and the end of the legacy-schedule exception (Q3); (b) System Administrator = the WorkPulse operator team, never a business user, and Super Admin (L35) = the business owner (Q42) | (a) both dates at the end of the second full payroll period after R3 / R4 deploy; (b) as stated | (a) until then not-reviewed employees and legacy schedules keep legacy behaviour; (b) only operators see all businesses; owners remain the L35 fallback inside their own business | (a) R5 cut-off only; (b) R3.5 only |
| D2 | **Central and floating cost label** (Q12) | One aggregate, "Allocated Central & Floating Staff Costs" | Branch reports show one line; individual details stay behind payroll-cost access | R11 labels only |
| D3 | **Branch-specific holidays** (Q4) | Business-wide only for now | Branches cannot observe different holidays until changed | R6 branch rows only |
| D4 | **Which payroll states block backdating a requirement change** (Q9) | From `under_review` onward (under review, branch review completed, finalized, paid) | Stricter than "locked": figures under review cannot silently change; HR must backdate before submission or correct through review | R3.2 backdating |
| D5 | **Schedules and the absence price:** (a) may an employee hold regular schedules at two branches at once (Q10)? (b) how is a monthly-paid absent day priced (Q11)? | (a) no for new assignments, successive only (A8), existing overlaps reported; (b) align with L28: monthly salary ÷ scheduled working days in the payroll period | (a) split-week staff need successive or coverage assignments; (b) changes absence deductions for every monthly employee versus today's ÷26, so communicate before go-live, with a parity report | R4 overlap rule; R7 |
| D6 | **Termination payout amount** (Q39) | Remaining days × (applicable monthly salary ÷ scheduled working days in the final payroll period), paid as a separate line in the final payroll entry | Leavers' unused leave is valued like unpaid-leave days; until decided, settlements stay "pending decision" | R7 payout only |
| D7 | **Held employees under L32** (Q40) | Finalized and paid late within the same period once resolved, cost shown Provisional until released | Others are paid on time; a held employee waits for the data fix; reports show their cost as provisional | R7, R10 |
| D8 | **Leave and correction confirmations:** (a) daily-paid employees remain unpaid-leave only, whatever the configured types (Q44, legal check advised); (b) the literal reading of the 31 March expiry (Q45 (d)); (c) no limit on correction resubmissions (Q41) | (a) yes (L6 stands); (b) literal; (c) no limit, full linked history | (a) no paid sick leave for daily-paid staff unless changed; (b) carry-overs made shortly before 31 March expire within days; (c) none beyond history volume | No — defaults are implementable and reversible |

### 18.6 Revision 8 — owner decisions recorded

#### 18.6.1 Decisions, questions closed and phases affected

| Decision **[A]** | Closes | Phases affected |
|---|---|---|
| D1 | Q3 (HR review / transition deadline only), Q42 (a)/(b) | R5 cut-off; R3.5 no longer waits for an owner decision (the G1 design still needs approval) |
| D2 | Q12 | R11 labels |
| D3 | Q4 (business part) | R6: business-wide only, no `branch_id` |
| D4 | Q9 | R3.2 fully ready |
| D5 (a) | Q10 | R4 overlap validation; R7 resolver unchanged |
| D5 (b) | Q11 | R7 absence pricing; Parity Report before rollout |
| D6 | Q39 | R6b settlement entry; R7 Final Payroll line |
| D7 | Q40 (business part) | R7.0 can start; its design needs separate approval |
| D8 (a) | Q44 | R6b |
| D8 (b) | Q45 (d) | R6b expiry job |
| D8 (c) | Q41 | R3b |

#### 18.6.2 Contradiction check

D1–D8 were checked against A–K, L1–L35, §6–§17, §18 and the Appendix.

| # | Finding | Handling |
|---|---|---|
| K1 | **D8 (b) differs from the revision 7 recommendation for Q45 (d).** Revision 7 recommended a literal reading: a carry-over just before 31 March expires on that 31 March. Its wording ("the first 31 March strictly after the carry-over date") also appeared in §6.7 and §12. D8 (b) says "31 March following the year in which they were carried over". | Not a conflict with an approved rule: L31's "31 March following the relevant carry-over" was ambiguous; D8 (b) settles it, and it matches L26's "31 March of the following year". §6.7, §12, §14 and §18.1 updated; L26 and L31 carry notes; the meaning of "year" is Q46 (e) |
| K2 | **D5 (b) changes today's absence deduction,** so §14 R7 ("unchanged employees … reproduce today's payroll") and §15 R7 ("absence parity spec for unchanged employees") would fail for every monthly employee with an absence | Parity narrowed to employees without absence or leave; absence differences go to the D5 (b) Parity Report, reviewed before rollout (§14, §15) |
| K3 | §16 risk "absence pricing stays per Q11 (unresolved)" | Replaced by the rollout risk of D5 (b) |
| K4 | **Gap: D5 (b) with L9 (1).** When part of a period is on a legacy assignment without weekdays, the D5 (b) denominator is incomplete | Not a contradiction of approved text; raised as Q46 (c), with a recommendation consistent with L9 (1) |
| K5 | D2 vs I: I names the aggregate "Allocated Central Staff Costs" | D2 is the later, more specific decision; I's privacy rule is unchanged. A refinement note was added to I without changing its text; §11, §13, §14 updated |
| K6 | D3 vs §8: the holiday table's optional `branch_id`, and revision 7's **[T]** "nullable `branch_id` kept for D3" | The column is removed from the first implementation **[T]**; A10 unchanged |
| K7 | D4 vs A5's "locked, finalized, approved or paid", and §6.1 / §12, which tested only locked periods | D4 is stricter and later; a note on A5; §6.1, §10, §12, §14, §15 updated. A5's reason and audit rules still apply before Under Review |
| K8 | **D5 (a) vs strategy A** (end + successor): the successor for an employee with a legacy cross-branch overlap is a new assignment. (§3.1 records that such overlaps are allowed today; that is current behaviour, not a rule) | The successor is refused until the overlap is ended: a **[T]** edge-case row in §12 and a risk row in §16; history not reinterpreted |
| K9 | D1 vs the revision 7 D1 request, which asked for two dates | D1 sets only the HR review deadline; the L9 (1) legacy-schedule end stays open (Q3). Recommendation: the same rule, counted from the R4 deployment |
| K10 | D6 vs L26 / L31 (payout configurable) | Consistent: D6 values the payout when the setting is "paid"; "forfeited" still writes a recorded forfeiture entry. The meaning of "approved daily rate" is Q46 (d) |
| K11 | D7 vs Q40's **[P]** "held entries cannot be paid" | Consistent: a held entry is not paid while held; after release it is finalized and paid in the same period. R7.0 designs it |
| K12 | D8 (a) vs L6 and L33 | Consistent: D8 (a) confirms L6, and limits configurable paid types to monthly-paid staff |
| K13 | D8 (c) vs L35 | Consistent |
| K14 | Pre-existing, not caused by D1–D8: §12's row "Monthly-paid employee on approved unpaid leave" still used L23's calendar-month denominator, which L28 superseded | Corrected to the payroll period (L28) |

No approved rule was reversed. Approved rows changed only by refinement or status notes: A2, A5, A10, I, L6, L25,
L26, L31, L32 and L35. In L25, the phrase "the transition deadline is unresolved" was replaced by a note pointing
to D1.

#### 18.6.3 R7.0 design gate — required content (D7 is not implementation approval)

*(Revision 14: the design is in §19.4, approval-ready, not approved.)*

R7.0 produces a design document that the owner and architecture review approve separately. Neither R7 nor R10
starts without that approval. The document must define:

1. **Lifecycle:** the employee-level payroll states and transitions (held, recalculated, reviewed, released,
   finalized, paid), and how they coexist with the period lifecycle and `PayrollPeriod#locked?`.
2. **Late finalization and payment** within the original period:
   * the interaction with PR #117's Salary Payment Hold (`salary_payment_holds`, `Payroll::ReleasedSalaryPayer`);
   * what happens when a hold is not released before the period ends or before the next period is finalized —
     a business choice to put to the owner with the design.
3. **Insurance expense recording** against the one-active-expense-per-period unique index
   (`idx_expenses_on_active_source_payroll_period`), e.g. G4's supplementary per-entry expense.
4. **Idempotency and duplicate prevention:** one live hold per entry; a release that succeeds once under
   concurrency; one supplementary expense and one snapshot set per entry; lock order request → period → entry.
5. **Accounting and reporting:** a held cost is Provisional until release (F, D7), then finalized; never mixed
   into finalized totals without a label.
6. **Audit, authorisation and reconciliation:** audit events for hold, release and late finalization; which
   permissions set, release and finalize a held entry; period totals reconcile to finalized plus released entries.
7. **Preservation:** already-finalized employee and period records are never edited; changes are append-only
   (H, CLAUDE.md money rules).
8. **Parity and contract:**
   * periods without holds behave exactly as today;
   * the `Payroll::CentralReview` fingerprint excludes held entries consistently;
   * `Payroll::FinalizationEffects` is extended once, in R10 (G8).

#### 18.6.4 Still open after revision 8

*(Superseded by revision 9: Q3 and Q46 are decided; see §18.7.3.)*

| Item | Kind | Recommendation | Blocks |
|---|---|---|---|
| Q3: end of the L9 (1) legacy-schedule exception | Owner | The same rule as D1 (1), counted from the R4 deployment | Only ending the legacy exception; not R4, R5 or R7 |
| Q46 (a)–(e) (§5) | Owner confirmation of interpretations | As in §5 | (a) R5 cut-off; (b)–(d) R7; (e) R6b expiry job |
| R7.0 design | Owner + architecture approval | §18.6.3 | R7, R10 |
| G1 platform-operator design | Architecture approval (module-boundaries §18) | §18.2 G1 | R3.5 |

The technical decisions **[T]** (§18.1–§18.3) are unchanged and need no owner decision.

### 18.7 Revision 9 — remaining owner decisions recorded

#### 18.7.1 Decisions, questions closed and phases affected

| Decision **[A]** | Closes | Phases affected |
|---|---|---|
| D9 | Q3 (the end of the L9 (1) legacy-schedule exception) | R4's deployment starts the count; R7 applies the end (legacy undefined days then block under C) |
| D10 | Q46 (a) | R5 cut-off counted from the R3.3 deployment |
| D11 | Q46 (b) | R7: one denominator setting for absence and unpaid leave |
| D12 | Q46 (c) | R7 absence in partly unscheduled periods; payroll-review warning |
| D13 | Q46 (d) | R6b settlement entry; R7 Final Payroll payout line |
| D14 | Q46 (e) | R6b carry-over and expiry job |

#### 18.7.2 Consistency check

D9–D14 were checked against D1, D3, D5 (b), D6, D8 (b), A–K, L1–L35, §6–§17, §18 and the Appendix.

| # | Finding | Handling |
|---|---|---|
| K15 | **D9 vs the revision 7 technical decision for Q3** ("enforcement starts with the first payroll period after the later date"), which joined the two deadlines | The **[T]** cell in §18.1 is replaced: two separate dates, each with its own effect. The §5 Q3 recommendation is kept for traceability only |
| K16 | **What happens when the L9 (1) exception ends.** D9 sets the end; L9 (1) allows finalization only "temporarily under this legacy exception" | After the D9 deadline, a required employee's dates on an assignment without working days have no working schedule, so C and L9 (2) apply: finalization is blocked for those dates until HR ends the assignment and creates a successor with working days (strategy A). This follows from approved rules; no new rule. Notes on A7 and L9; §6.4, §6.5, §10, §12, §14, §15 and §16 updated |
| K17 | **D12 differs from the revision 8 recommendation for Q46 (c),** which was "no absence deduction for that employee in that period" | D12 governs: absence is calculated normally for the reliably scheduled dates, and only the unscheduled portion is skipped. §6.4, §12, §14 and §15 updated |
| K18 | **D12's scope vs C, L9 (2) and L32.** D12 allows finalization for a partly unscheduled period; C blocks finalization for a required employee with no applicable assignment and schedule; L32 holds an employee whose unpaid-leave deduction cannot be calculated | Read together, none of them changed: D12 governs absence pricing; C (and L9 (2) after the D9 deadline) still blocks where its own condition is met; L32 still flags unpaid leave on unscheduled dates. In practice D12 applies to legacy assignments without working days before the D9 deadline. If the owner meant D12 to override C, that is a change to C and needs an explicit decision |
| K19 | **The rate for partial periods.** D5 (b)'s divisor is the Scheduled Working Days of the whole Payroll Period. For the scheduled dates of a partly unscheduled period (D12), for joiners and leavers, and for a leaver's final period (D13), only part of the period counts. Counting only those days raises the price of each day; estimating the rest is forbidden | Raised as **Q47** (§5) with a recommendation; it blocks R7 only for these cases. The joiner and leaver part already existed in revision 8 and was not flagged then |
| K20 | **D11 names public holidays only,** while the Holiday Calendar also holds company holidays (A10, D3) | Applied literally **[T]**: the setting covers approved public holidays; company holidays stay in the denominator and are never absences (A10). Widening the setting later is a configuration change |
| K21 | **D13's "relevant dates"** for a payout, whose leave days carry no dates | **[T]** The Payroll Period is the final one, where the payout line is (D6); the salary profile is the one in force on the employment end date (`employment_ended_on`, Q5 **[T]**); the schedule rules are those of D5 (b), D11 and D12. A partial final period is Q47 (c) |
| K22 | **"Complete Payroll Period"** in D1 (1) / D10 and D9 | **[T]** A Payroll Period counts when it starts after the deployment date (business day); the deadline is the last day of the second such period. Each date is computed once per business at deployment and recorded (§8) |
| K23 | **D14 vs L31** (individual leave year) | Consistent: the carry-over happens at each employee's leave-year anniversary, so an employee has at most one carry-over batch per calendar year. **[T]** The calendar year is that of the effective date in the business's time zone (`BusinessDay`), never the server date (§6.7) |
| K24 | D14 vs D8 (b) and L26 | Consistent: "31 March of the following year" (L26), "31 March following the year in which they were carried over" (D8 (b)) and D14 give the same date |
| K25 | D10 vs D1 (1) and L25 | Consistent: HR-exception-list employees share the Not Reviewed deadline, counted from R3.3, which is also the phase that creates the exception list |
| K26 | A deadline can pass before its enforcing phase is deployed (R5 for D1 (1); R7, which waits for R7.0, for D9) | The deadlines are not moved. **[T]** Enforcement starts when the enforcing phase is deployed; R7 applies the D9 end from the first Payroll Period it calculates, after a clean read-only preview (§16) |

No approved rule was reversed. Approved rows changed only by notes: A7, L9, L25, L26, L28 and L31, and D1, D5, D6
and D8 in §2 M.

#### 18.7.3 Still open after revision 9

*(Superseded by revision 10: Q47 is decided as D15; see §18.8.4.)*

| Item | Kind | Recommendation | Blocks |
|---|---|---|---|
| Q47 (a)–(c) (§5) | Owner business decision | As in §5 | R7, for partly scheduled or partly employed periods only |
| R7.0 design | Owner + architecture approval | §18.6.3 | R7, R10 |
| G1 platform-operator design | Architecture approval (module-boundaries §18) | §18.2 G1 | R3.5 |

D9–D14 do not authorise R7.0, G1 or any implementation phase. The technical decisions **[T]** are unchanged apart
from the Q3 cell (K15) and the application points K20–K23 and K26, which are engineering-reviewable.

### 18.8 Revision 10 — Q47 recorded as D15

#### 18.8.1 Decision, question closed and phases affected

| Decision **[A]** | Closes | Phases affected |
|---|---|---|
| D15 | Q47 (a)–(c) | R7: absence and unpaid-leave deductions and the payout rate for partial schedules, joiners and leavers; R6b: the settlement entry records days only, unchanged |

**How D15 is applied [T]** (the approved rule is the §2 O text; this is its reading in this plan):

```
eligible dates E   = dates of the Payroll Period inside the employment window with a reliable schedule
                     (D12); dates blocked under C or L9 (2) are not in E
numerator          = salary actually attributable to E — the amount payroll attributes to those dates,
                     split at salary-profile changes; nothing after the employment end date (OT3)
denominator        = reliable scheduled working days in E, rest days excluded, public holidays per the
                     D11 setting
absence            = Σ over absent days in E of daily_rate(d)
unpaid leave       = Σ over unpaid-leave workdays in E of daily_rate(d)
payout (D6, D13)   = remaining eligible leave days × daily_rate(employment end date), E taken in the
                     final Payroll Period
fully eligible     = E is the whole period → daily_rate = applicable monthly salary ÷ scheduled
                     working days in the Payroll Period, exactly D5 (b) / L28
daily-paid staff   = unaffected: pay = rate × approved attendance days (A9, L6)
```

#### 18.8.2 Consistency check

D15 was checked against D5 (b), D6, D12, D13, D14, L23, L26, L28, L31, L32, A–K, §6–§17, §18 and the Appendix.

| # | Finding | Handling |
|---|---|---|
| K27 | **D5 (b), L28 and D13 name "Scheduled Working Days in Payroll Period".** Read literally for a partial period, the full monthly salary would be divided by a partial denominator, which D15 forbids | D15 refines all three for partial eligibility; for a fully eligible period they are unchanged. Notes on L28, D5, D6, D12 and D13; formulas in §6.4, §6.7, §7, §12, §14 and §15 updated |
| K28 | **L23 and the §1 summary** state the full-period formula | L23 is already superseded by L28; the §1 bullet carries a D15 note. L23's row is kept as approved history |
| K29 | **K21 [T] (payout at the profile in force on the employment end date) vs D15's "split at salary changes"** | Compatible: the payout has one rate, taken at the end date's profile over the final period's eligible dates; how the split works for a single rate is OT2 / OT3 |
| K30 | **No schedule at all.** Central employees (B) have no assignment and no scheduled working days, so the D15 / L28 denominator is zero for every date, and unpaid leave can never be priced; L32 would flag every case. This gap existed before D15 and was not flagged earlier | Not a technical detail: raised as owner question **Q48** (§5), with L32 applied as approved until decided |
| K31 | **Zero scheduled days inside E** | Absence and unpaid leave cannot arise (both count only scheduled days), so no deduction is due. A payout can arise (a leaver whose final window has no scheduled day): **OT1** *(revision 15: D22)* |
| K32 | **The revision 9 Q47 recommendation's fallback** ("unpaid leave or a payout is Flagged for Review" when no scheduled day exists) is not in the owner's D15 wording | Not adopted as a rule. Kept as the OT1 recommendation, which needs owner confirmation if it becomes a business rule |
| K33 | D15 vs D14, D8 (b), L26 and L31 carry-over and expiry | Unaffected: carry-over, expiry and FEFO work in days; the rate is applied only at settlement (D6) |
| K34 | D15 vs D12 | Consistent: D12 removes the unscheduled dates; D15 prices the remaining dates over themselves only |
| K35 | D15 vs the Parity Report (D5 (b)) | Fully eligible periods are unchanged; partial periods differ from today's ÷ `working_days_per_month` and are shown in the report |
| K36 | D15 vs L32 and the R7.0 gate | Consistent: a held employee is priced by the same rule when released; D15 does not authorise R7.0 |

No approved rule was reversed. Approved rows changed only by notes: L26, L28, L31, D5, D6, D12 and D13.

#### 18.8.3 Open technical issues

*(Revision 14: OT2 and OT3 resolved in §19.3; OT1 is owner question Q52, decided in revision 15 as D22, details
Q54, decided in revision 16 as D24–D27.)*

These do not change the business rule. Engineering settles them in R7's design review; a resolution that changes a
fully eligible period's result, or that would create a new business rule, goes to the owner instead.

| # | Issue | Recommendation | Blocks |
|---|---|---|---|
| OT1 | Payout for a leaver whose final period's eligible dates contain no scheduled working day (denominator zero) | Flagged for Review; the payout line waits and the balance is never silently paid or forfeited (D6). Taking a rate from another period would be a business rule, so it goes to the owner if wanted | R7 payout, that case only |
| OT2 | Splitting at salary changes. Reading (i): each segment's own salary for its dates ÷ that segment's own scheduled days. Reading (ii): each date's profile salary scaled to the whole eligible range E ÷ scheduled days in E. Reading (i) changes the D5 (b) / L28 result for a fully eligible period with a mid-period salary change; reading (ii) does not | Reading (ii): daily_rate(d) = M(d) × attributable share of E ÷ scheduled days in E, where M(d) is the monthly salary in force on d. It equals D5 (b) / L28 for fully eligible periods and D15's "attributable ÷ scheduled" without a salary change. A spec pins both equalities | R7 rate code |
| OT3 | Attribution basis of the numerator: "salary actually attributable" must be the basis payroll already pays on (today a calendar-day proration in `BasicSalaryCalculator` / `salary_breakdown`, PR #111), so that no deduction exceeds what was earned | Reuse that basis exactly and re-verify it on the new baseline (§18.4); never a separate proration | R7 rate code |

#### 18.8.4 Still open after revision 10

*(Superseded by revision 11: Q48 is decided as D16; see §18.9.4.)*

| Item | Kind | Recommendation | Blocks |
|---|---|---|---|
| Q48 (§5) | Owner business decision | Keep L32 until decided | Unpaid leave for employees without a schedule (R6b, R7) |
| OT1–OT3 (§18.8.3) | Technical | As in §18.8.3 | R7 rate code |
| R7.0 design | Owner + architecture approval | §18.6.3 | R7, R10 |
| G1 platform-operator design | Architecture approval (module-boundaries §18) | §18.2 G1 | R3.5 |

D15 does not authorise R7.0, G1 or any implementation phase.

### 18.9 Revision 11 — Q48 recorded as D16

#### 18.9.1 Decision, question closed and phases affected

| Decision **[A]** | Closes | Phases affected |
|---|---|---|
| D16 | Q48 | R7: unpaid-leave deduction for monthly-paid employees without a work schedule (Calendar-day Proration). No effect on R4, R5 or R6b classification, schedules or leave approval |

Which calculation applies **[A]** (the formula details are not decided here):

```
monthly-paid employee, unpaid-leave date d
  reliable schedule on d             → scheduled-day proration (D5 (b) basis, L28, D15)
  no work schedule (e.g. central, B) → Calendar-day Proration (D16); formula: OT4–OT8
  required employee, schedule missing or unreliable on d
                                     → unchanged: C where it applies, otherwise L32;
                                       never D16 (D17, revision 12)
absence (any employee)               → scheduled-day proration only; never D16
daily-paid employee                  → unchanged (A9, L6): unpaid leave is unpaid, no deduction formula
```

#### 18.9.2 Consistency check

D16 was checked against D5 (b), D6, D12, D13, D15, B, C, E, I, L6, L16, L23, L26, L28, L31, L32, §6–§17, §18 and the
Appendix.

| # | Finding | Handling |
|---|---|---|
| K37 | **Scope of "employees who do not have a work schedule".** Read broadly, it would also cover required employees whose schedule is missing (C, L9 (1), D12), where C blocks finalization and L32 flags unpaid leave | Not decided silently: raised as **Q49 (a)**. Until then D16 applies to employees without a schedule by design (not required to attend), and C, D12 and L32 apply unchanged to required employees |
| K38 | **D16 vs L23 / L28** ("from the employee's actual scheduled working days"; "no fixed 30-day or 26-day divisor") | D16 is the specific rule for employees with no scheduled days, so L28's scheduled-day basis cannot apply to them; L28 is unchanged for everyone else (note on L28). L28's ban on a fixed 30 still binds the D16 formula: OT4 must use actual calendar days |
| K39 | **D16 vs L32** (unreliable unpaid-leave deduction → Flagged for Review) | An employee without a schedule by design is no longer flagged for that reason alone; L32 still applies to every other unreliable case (note on L32) |
| K40 | **D16 vs D15** (same eligible dates in numerator and denominator) | Kept distinct: D15 is scheduled-day proration, D16 calendar-day proration. Whether D15's same-dates principle also shapes the D16 formula (the leave-day count against the calendar-day denominator) is OT4 / OT8, not assumed |
| K41 | **D16 covers unpaid leave only, but D6 / D13 / D15 price the termination payout per scheduled day,** which is undefined for an employee without a schedule | Not extended silently: raised as **Q49 (b)**; until decided, such a payout is Flagged for Review (OT1) |
| K42 | D16 vs D5 (b) absence | Consistent: an employee without a schedule has no scheduled days, so no absence; D16 is never used for absence (notes on D5, D15) |
| K43 | D16 vs B, E, I and J (central classification, insurance, privacy, allocation) | Consistent: the classification, allocation rule and privacy are unchanged; the deduction reduces the salary that is then allocated as for any employee. Whether employer insurance follows the reduced salary is today's payroll behaviour, unchanged |
| K44 | D16 vs L6, A9 (daily-paid) | Consistent: D16 is for monthly-paid employees; daily-paid employees always require attendance and have a schedule |
| K45 | D16 vs D11 (holiday setting) | D11 names the scheduled-day denominators; whether holidays affect the calendar-day denominator is part of OT4, not assumed |
| K46 | D16 vs the Parity Report (D5 (b)) | No parity effect: no leave exists today (§3.6), so central unpaid leave has no current result to compare |
| K47 | D16 vs L31 (accrual continues during unpaid leave) and D14 | Unaffected: D16 prices the deduction only |

No approved rule was reversed. Approved rows changed only by notes: B, L28, L32, D5 and D15.

#### 18.9.3 Open technical questions for the R7 design review

*(Revision 14: OT4–OT8 resolved in §19.3.)*

D16 sets the rule; these details are not decided. Any proposed answer that introduces a new business rule, or
changes a full-period payroll result, returns to the owner for approval.

| # | Question | Constraints already approved | Blocks |
|---|---|---|---|
| OT4 | Calendar-day denominator: the actual number of calendar days in the calendar month, or in the actual Payroll Period (they differ when the period is not a calendar month)? Do holidays affect it (K45)? | Actual calendar days, never a fixed 30 (L28); no scheduled days invented (D16) | R7, D16 formula |
| OT5 | Salary changes inside the period: how the profile in force on each leave date is applied and the calculation split | Effective-dated salary profiles respected (L28; same principle as D15) | R7, D16 formula |
| OT6 | Partial employment and mixed periods: joiners, leavers, and an employee who has a schedule for part of the period (e.g. becomes central mid-period) | No unearned salary counted, no full monthly salary against a partial denominator (D15's principle); the scheduled part keeps D15 | R7, D16 formula |
| OT7 | Rounding: at which step amounts are rounded, and to how many decimals | Money stored as decimal, never floats (CLAUDE.md); the existing payroll rounding is the reference | R7, D16 formula |
| OT8 | Leave-day count: is every calendar day of the approved leave counted, or only some days, given there is no schedule to say which days are working days? | Must use the same calendar-day basis as the OT4 denominator; no scheduled days invented (D16) | R7, D16 formula |

#### 18.9.4 Still open after revision 11

*(Superseded by revision 12: Q49 is decided as D17 and D18; see §18.10.4.)*

| Item | Kind | Recommendation | Blocks |
|---|---|---|---|
| Q49 (a), (b) (§5) | Owner business decision | As in §5 | R7: D16's scope; payout for employees without a schedule |
| OT4–OT8 (§18.9.3) | Technical, R7 design review | Within the approved constraints; owner approval for anything beyond them | R7 unpaid leave for employees without a schedule |
| OT1–OT3 (§18.8.3) | Technical | As in §18.8.3 | R7 rate code |
| R7.0 design | Owner + architecture approval | §18.6.3 | R7, R10 |
| G1 platform-operator design | Architecture approval (module-boundaries §18) | §18.2 G1 | R3.5 |

D16 does not authorise R7.0, G1 or any implementation phase.

### 18.10 Revision 12 — Q49 recorded as D17 and D18

#### 18.10.1 Decisions, question closed and phases affected

| Decision **[A]** | Closes | Phases affected |
|---|---|---|
| D17 | Q49 (a) | R7: D16 used only when the requirement in force on the leave date is not required |
| D18 | Q49 (b) | R6b: held settlement keeps the balance and creates the pending review case; R7: final payroll without a payout line for these leavers |

Which rule applies at termination **[A]**:

```
employee leaves with unused eligible leave
  settlement setting "forfeited"                       → recorded forfeiture entry (L26, L31, D6)
                                                          — except: not required + no schedule → Q50 (a),
                                                          held until decided
  setting "paid", reliable schedule in the final period → payout line at the D13 / D15 rate (D6)
  setting "paid", required, no scheduled day in window → D22 reference-period rate (rev. 15; was OT1)
  not required to attend + no schedule at the end       → HELD for HR/Payroll review (D18): pending case,
                                                          balance and history kept, no automatic payment,
                                                          no forfeiture, erasure or zeroing
```

*(Superseded by revision 13 for the held case: the hold applies under both settings (D19) and is released under
D20; see §18.11.1.)*

#### 18.10.2 Consistency check

D17 and D18 were checked against D6, D13, D15, D16, B, C, A2, A3, A4, L4, L9, L25, L26, L28, L31, L32, D8 (b),
D12, §6–§17, §18 and the Appendix.

| # | Finding | Handling |
|---|---|---|
| K48 | **D17 names `requires_attendance = false`,** the cache column; A3 and L4 make the effective-dated `employee_attendance_requirements` history the source of truth and forbid using the cache for checks | **[T]** Read as "the requirement in force on the leave date is not required" in the history; the cache is never read for this check. This reading keeps the business meaning and changes no rule |
| K49 | **Not Reviewed and HR-exception-list employees** (A2, L4, L25) are never classified "not required" | Consistent: they never use D16 (D17); unpaid leave without a reliable schedule is Flagged for Review (L32). No classification changes |
| K50 | **D18 vs the configurable termination settlement** (L26, L31, D6: "forfeited" writes a recorded forfeiture entry). D18 forbids forfeiture for these leavers | Not decided silently: **Q50 (a)**. Until decided, held in both cases (reversible). *(Decided as D19, revision 13.)* |
| K51 | **D18's "until a reliable payout calculation … is available"**: no such calculation is approved | **Q50 (b)**, non-blocking; the hold needs no calculation. *(Decided as D20, revision 13: the calculation's formal approval is a release condition.)* |
| K52 | **D18 vs carry-over expiry (D8 (b), D14) and accrual (L31)** after employment ends: a batch expiring while the settlement is held would reduce the balance, which D18 forbids | **[T]** The held amount is the balance in days as of the employment end date; no expiry, forfeiture or accrual entry is written after that date while the case is pending. This follows from D18 and L31's proration at the end of employment |
| K53 | **D18 vs the final payroll (D6 "a separate Final Payroll line")** | **[T]** The final payroll is finalized normally without the payout line; D18 holds the leave settlement only, not the employee's payroll (L32 / D7 are not triggered). A later payout after the period is locked follows a separate audited process, as for post-lock leave (L21), never by reopening the period: OT9 |
| K54 | **D18 vs the revision 11 Q49 (b) recommendation** (Flagged for Review) | D18 governs; it adds the pending record and the ban on forfeiture or zeroing |
| K55 | D17 vs A4 (not required → no `ShiftAssignment`) | Consistent: a not-required employee has no assignment, so "no work schedule" always holds for D17's group; D17 creates none |
| K56 | D17 vs C, D12, L9 (1)/(2), L32 | Consistent: these controls stay for required employees (notes on L32, D16) |
| K57 | D18 vs OT1 | D18 covers only leavers who do not require attendance; required leavers with no scheduled day stay under OT1, decided as D22 (revision 15) |
| K58 | D17 and D18 vs B, E, I, J | Consistent: classification, allocation, insurance and privacy unchanged |

No approved rule was reversed. Approved rows changed only by notes: B, L26, L31, L32, D6 and D16.

#### 18.10.3 Open technical question

| # | Question | Constraints already approved | Blocks |
|---|---|---|---|
| OT9 | Resolution path for a held settlement (D18): which permission reviews and resolves it, whether resolution needs a second approver, and how a payout approved after the final period is locked is paid (a separate audited process, never reopening the period) | D18 (never automatic, never forfeited or zeroed, history preserved, authorised resolution); L21 / L35 precedents for post-lock corrections; audit of every step | R6b / R7 settlement code. A resolution that needs a new approval rule goes to the owner |

#### 18.10.4 Still open after revision 12

*(Superseded by revision 13: Q50 is decided as D19 and D20, and OT9 is narrowed; see §18.11.4.)*

| Item | Kind | Recommendation | Blocks |
|---|---|---|---|
| Q50 (a), (b) (§5) | Owner business decision | As in §5; hold meanwhile | Non-blocking |
| OT1–OT3 (§18.8.3), OT4–OT8 (§18.9.3), OT9 (§18.10.3) | Technical, R7 design review | Within the approved constraints; owner approval for anything beyond them | R7 (and R6b for OT9) |
| R7.0 design | Owner + architecture approval | §18.6.3 | R7, R10 |
| G1 platform-operator design | Architecture approval (module-boundaries §18) | §18.2 G1 | R3.5 |

D17 and D18 do not authorise R7.0, G1 or any implementation phase.

### 18.11 Revision 13 — Q50 recorded as D19 and D20

#### 18.11.1 Decisions, question closed and phases affected

| Decision **[A]** | Closes | Phases affected |
|---|---|---|
| D19 | Q50 (a) | R6b: the `Pay Out` / `Forfeit` setting kept as is; the hold applies under both; the release applies the configured setting |
| D20 | Q50 (b) | R6b: review-case steps and the release guard; R7: any payout after release, at the approved calculation only |

Held settlement lifecycle **[A]** (status names **[T]**):

```
employee not required to attend leaves, no schedule at the end (D18)
  │  under Pay Out or Forfeit alike (D19); held amount = balance in days at the employment end date (K52)
  ▼
PENDING   no payment, no forfeiture, erasure or zeroing; no ledger entry; listed for HR/Payroll review
  │  (1) payout calculation for employees who do not require attendance formally approved (owner, future)
  │  (2) HR reviews the employment details and the leave balance
  │  (3) Payroll reviews and approves the settlement amount
  ▼  all of (1)–(3) recorded; any one missing → stays PENDING (D20)
RELEASED  (4) the business's configured setting is applied (D19; version: Q51)
            Pay Out → one termination_settlement entry; paid through payroll, after a locked final
                      period by a separate audited process, never reopening it (OT9)
            Forfeit → one recorded forfeiture entry, with the review history behind it
            never Forfeit converted into Pay Out
history kept throughout: accrual, hold, each review step, release and settlement
```

The distinctions D19 and D20 preserve:
* **The business setting is the normal policy** for that business (D19). It settles every leaver outside D18 exactly
  as before (D6, L26, L31).
* **D18 is a specific, temporary hold**, not a replacement of the setting: it ends at release, when the setting
  applies.
* **A held balance is an existing entitlement whose payout decision is pending**, never a forfeited or zero balance.
* **`Forfeit` applied after release** is a reviewed, recorded entry with HR's review and Payroll's approval behind
  it. Silently forfeiting a balance while it is held is forbidden.

#### 18.11.2 Consistency check

D19 and D20 were checked against D6, D7, D8 (b), D13–D18, B, L21, L26, L31, L32, K21, K48–K58, §6–§17, §18 and the
Appendix.

| # | Finding | Handling |
|---|---|---|
| K59 | **Setting labels.** D19 names `Pay Out` / `Forfeit`; L26, L31, D6 and §8 call the same setting "paid" / "forfeited" (`termination_settlement` `paid` / `forfeited`) | **[T]** One setting: `Pay Out` / `Forfeit` are its Business Settings labels (EN and AR keys). No value is renamed or added and no business's setting changes |
| K60 | **D19 vs the Q50 (a) recommendation** (hold under both settings; a confirmed forfeiture is a recorded entry) | Consistent: D19 confirms it and adds that `Forfeit` is never converted into `Pay Out` |
| K61 | **D19 vs D6, L26 and L31** ("under 'forfeited', a recorded forfeiture entry is written") | Consistent: unchanged for every leaver outside D18; for a D18 case the forfeiture entry is written only at release, after D20 (notes on D6, L26, L31) |
| K62 | **Which version of the setting applies at release.** Leave policies are versioned by `effective_from` (§8); D19 applies "the business's configured termination policy" after release, which may come long after the employment end date | Not decided silently: **Q51**. Non-blocking: nothing is released before D20 (1). The release records the version it applied. *(Decided as D21, revision 14: the snapshot at the employment end date.)* |
| K63 | **D20 (1) under `Forfeit`.** A forfeiture needs no payout calculation, but D20 requires all of its conditions | Applied as written: a held settlement under `Forfeit` also waits for D20 (1). Not reinterpreted |
| K64 | **D20 (1), the payout calculation** | Not designed or assumed here: not D13 (no denominator without a schedule, §18.9.2 K41) and not D16 (unpaid leave only). Its formal approval is a future owner decision; until then every held settlement stays pending |
| K65 | **Order of D20 (2) and (3)** | **[T]** Payroll's approval (3) follows the approved calculation (1), since the amount is computed by it; HR's review (2) may be recorded earlier; (4) comes last. A different order or a combined step is OT9 |
| K66 | **D20 vs OT9** | D20 settles which reviews are required (HR and Payroll) and that release needs every condition; OT9 keeps the permissions, whether one person may perform both steps, rejected reviews and the post-lock payout path |
| K67 | **D20 vs K52 and K53** | Consistent: the held amount stays fixed at the employment end date; the final payroll stays finalized without the payout line; a payout after release never reopens a locked period (L21 precedent) |
| K68 | **D20's "review history"** extends D18's "accrual and settlement history" | **[T]** The review case keeps each step (actor, timestamp, reason) append-only (§8, §11) |
| K69 | D19 / D20 vs D16, D17, L32 and D7 | Consistent: unpaid leave, classification, the per-employee finalization block and held-employee payroll are unchanged; D18's hold is not an L32 / D7 hold (K53) |
| K70 | D19 / D20 vs B, E, I, J | Consistent: classification, allocation, insurance and privacy unchanged |

No approved rule was reversed. Approved rows changed only by notes: B, L26, L31, D6, D13, D16 and D18.

#### 18.11.3 Open technical question (narrowed)

*(Revision 14: resolved in §19.3 except the same-person point, owner question Q53, decided in revision 15 as D23.)*

| # | Question | Constraints already approved | Blocks |
|---|---|---|---|
| OT9 | Steps of a held settlement's release (D18, D20): which permissions record the HR review and the Payroll approval (precedent: the Historical Violation split in §10), whether one person may perform both, how a rejected review is recorded and returned for review, and how a payout released after the final period is locked is paid (a separate audited process, never reopening the period) | D18–D20 (every condition, never automatic, never forfeited or erased while pending, full history); L21 precedent for post-lock effects; audit of every step | R6b / R7 settlement code. A same-person rule or any other new approval rule goes to the owner |

#### 18.11.4 Still open after revision 13

*(Superseded by revision 14: Q51 is decided as D21; see §19.2 and §19.12.)*

| Item | Kind | Recommendation | Blocks |
|---|---|---|---|
| Q51 (§5) | Owner business decision | The setting in force on the employment end date | Non-blocking (release only) |
| Payout calculation for employees who do not require attendance (D20 (1)) | Future formal owner approval | None proposed in this plan | Release of held settlements only |
| OT1–OT3 (§18.8.3), OT4–OT8 (§18.9.3), OT9 (narrowed, §18.11.3) | Technical, R7 design review | Within the approved constraints; owner approval for anything beyond them | R7 (and R6b for OT9) |
| R7.0 design | Owner + architecture approval | §18.6.3 | R7, R10 |
| G1 platform-operator design | Architecture approval (module-boundaries §18) | §18.2 G1 | R3.5 |

D19 and D20 do not authorise R7.0, G1 or any implementation phase, and approve no payout formula.

---

## 19. Revision 14 — consolidated architecture specification

This section is the **consolidated specification** of the plan. It is written so that an engineer can implement a
phase from it without reading the revision history. Revision 15 updates it for D22 and D23,
revision 16 for D24–D27.

**Precedence:**
* The rule texts in §2 (A–K, L1–L35, D1–D27) are the binding wording of every owner decision. §19.1 summarises
  them; if a summary here reads differently from §2, §2 governs and the summary is a defect to fix.
* For technical design (**[T]** / **[P]**), §19 governs. Where an earlier section (§6–§18) differs from §19, the
  earlier text is superseded and kept only as history. The main superseded places carry a pointer to §19.
* Nothing in §19 is implementation approval. R7.0 (§19.4) and G1 (§19.5) are **approval-ready designs**, not
  approved designs. Every phase still needs its own owner authorisation (§19.12).

### 19.0 Re-baseline evidence (revision 14) **[C]**

Read-only inspection: the local branch, `origin/main` through `git show` (nothing fetched, no branch switched) and
the stash list (not opened or changed). `origin/main` is `3e01ac3` (PRs #116 and #117 merged after the plan's
baseline `7585f16`); the local `main` ref is still `7585f16`.

| Area | Evidence on `origin/main` `3e01ac3` |
|---|---|
| Payroll Period | One per business per calendar month (unique `(business_id, period_year, period_month)`); `period_start` = the 1st, `period_end` = the month's last day (`app/models/payroll_period.rb`); statuses `draft → under_review → branch_review_completed → finalized → paid`; `locked?` = finalized or paid. `payroll_cutoff_day` is an attendance cut-off, not a different period range |
| Payroll entry | One per employee per period (unique `(payroll_period_id, user_id)`); `status` `draft` / `approved` / `disputed`; `salary_breakdown` refused while the period is locked; `employee_visible` = entries of finalized or paid periods |
| Finalization | `Payroll::Approver#advance`: period row lock, status re-check, `Payroll::CentralReview#sync!`, refusal while adjustments are pending or entries carry `recalculation_review_required`, then `period_finalized` through `Payroll::FinalizationEffects`; the whole period is finalized at once |
| Payment | `finalized → paid` settles advances for every entry, then `Payroll::SalaryWithholder` withholds entries of employees under an active Salary Payment Hold (#117) |
| Reopen | `Payroll::Reopener`: `paid → finalized` refused when a withheld entry was already disbursed, otherwise live withholdings are voided; `finalized → branch_review_completed` calls `period_reopened`, which voids the insurance expense |
| Payroll → Finance contract | `Payroll::FinalizationEffects::OPERATIONS = [period_finalized, period_reopened]`; synchronous, in the caller's transaction, registered at boot |
| Insurance expense | `Finance::PayrollInsuranceExpense`: one active expense per `(source_payroll_period_id, unallocated)` (partial unique index `idx_expenses_on_active_source_payroll_period`); `expense_date = period_end`; skipped when any active one exists; voided (status `cancelled`) on reopen; check constraint `expenses_unallocated_payroll_only` |
| Insurance amounts | From `EmployeeInsuranceProfile`, frozen once the period has ever been finalized (`Payroll::EntryCalculator#resolve_insurance_snapshot`); not derived from salary lines, so a leave payout line does not change insurance. The snapshot path converts amounts with `.to_f` (§19.8 R-14) |
| Basic salary | `Payroll::BasicSalaryCalculator`: per salary-profile portion; monthly = `base × portion calendar days ÷ period calendar days`, or the starter working-days rule for a first profile starting after the 1st; exact `Rational`, the total rounded **once** to cents half up, portions apportioned by largest remainder |
| Salary Payment Hold (#117) | `salary_payment_holds` (one active per employee), `salary_payment_withholdings` (one live per entry, disbursement and void columns with check constraints), `Payroll::ReleasedSalaryPayer` (period lock, then withholding lock, `log_audit!`), `SalaryPaymentHoldPolicy` excludes the actor's own record, the bank CSV excludes held entries |
| Separation of duties | `Approvals::SelfApproval.by_requester?` and `Payroll::AdjustmentApproval` (with a business-owner exception) are the only creator ≠ approver rules |
| Payroll permissions | `view_payroll`, `view_draft_payroll`, `create_payroll`, `regenerate_payroll`, `submit_payroll_review`, `complete_branch_review`, `approve_payroll_items`, `manage_payroll_overrides`, `manage_payroll_deduction_waivers`, `finalize_payroll`, `pay_payroll`, `reopen_payroll`, `delete_payroll` and others (`PermissionRole::PERMISSION_GROUPS[:payroll]`); `view_salary_payment_holds` / `manage_salary_payment_holds` in the employees group |
| Authentication | One Devise scope, `:user`, with `database_authenticatable`, `registerable`, `recoverable`, `rememberable` only (no `lockable`, `timeoutable`, `trackable`, `confirmable`); password length 6–128; reset tokens valid 6 hours; no MFA gem in the `Gemfile`; no model uses `encrypts` (whether Active Record encryption keys exist in credentials was not inspected: secrets are not read); `users.business` presence validated; the API uses the same Devise session; `ApplicationController` has no `verify_authorized` hook |
| Admin namespace | `Admin::BaseController#require_admin_access!` admits holders of 13 ordinary business permissions; it is a business-user area, not a platform area |
| Audit | `audit_logs.actor_id` and `business_id` NOT NULL; `log_audit` savepoint, `log_audit!` raises `AuditWriteFailed` (BUG-003 policy) |
| Production | `config.force_ssl = false` (TLS termination at the proxy is assumed, not verified here) |

### 19.1 Consolidated owner decisions D1–D27 **[A]**

Every decision below is approved. The meaning column is a faithful summary; §2 holds the binding text. "Final
rule" names the later decisions that refine it; no decision below is reversed by a later one.

| ID | Final approved meaning | Refined by | Applied in |
|---|---|---|---|
| D1 | (1) Not Reviewed HR deadline = end of the 2nd complete Payroll Period after deployment (of R3.3, D10); HR-exception-list employees count as Not Reviewed. (2) System Administrator = the WorkPulse platform operations team. (3) Super Admin = the business owner. (4) Platform and business access are separate in both directions | D10 | R3.3, R5, G1 (§19.5) |
| D2 | Report label "Allocated Central & Floating Staff Costs": one aggregate line; no names or individual salaries in ordinary branch reports | — | R11 |
| D3 | One business-wide holiday calendar; no branch calendars in this phase | — | R6 |
| D4 | Backdated requirement change refused once an affected period is `under_review` or later; before that, A5 controls (reason, audit, no locked period) | — | R3.2 |
| D5 | (a) No new regular assignment overlapping the same employee's regular assignment at another branch; history not reinterpreted. (b) Monthly absence = Applicable Monthly Salary ÷ Scheduled Working Days in Payroll Period × Absence Days, salary profile per date, split at profile boundaries, never a fixed divisor; Parity Report before rollout; absence and unpaid leave never deduct the same date twice | D11, D12, D15 | (a) R4; (b) R7 |
| D6 | Termination payout = remaining eligible leave days × approved daily rate; a separate Final Payroll line; balance and settlement history kept; never paid or forfeited silently; under the business's `Forfeit` setting a recorded forfeiture entry | D13, D15, D18–D22, D24–D27 | R6b (ledger), R7 (payout line) |
| D7 | Held-employee principle: others finalized and paid on time; held employee's entitlements still calculated; held employee finalized and paid later within the same Payroll Period; held cost Provisional until released. Principle only: R7.0 needs its own approval | — | R7.0 design (§19.4), R10, R7, R11 |
| D8 | (a) Daily-paid: Unpaid Leave only. (b) Carry-over expires 31 March following the carry-over year, FEFO. (c) No maximum correction resubmissions; each one linked, full history kept | D14 | (a)(b) R6b; (c) R3b |
| D9 | L9 (1) legacy exception ends at the end of the 2nd complete Payroll Period after R4 deployment, separate from D1 (1) | — | R4, R7 |
| D10 | "After deployment" in D1 (1) = after R3.3 deployment | — | R3.3, R5 |
| D11 | The public-holiday exclusion setting also applies to the absence divisor | — | R7 |
| D12 | Partly unscheduled period: no deduction for the unscheduled portion, a warning, finalization allowed, normal calculation for scheduled dates | D15 | R7 |
| D13 | D6 payout rate = D5 (b) daily rate (Applicable Monthly Salary ÷ Scheduled Working Days), profile of the relevant dates | D15; no rate without a schedule (D18); required leaver without a scheduled day in the final period (D22, D24–D27) | R7 |
| D14 | D8 (b)'s "year" = the calendar year of the carry-over | — | R6b |
| D15 | Numerator and denominator over the same eligible dates; numerator = salary actually attributable; denominator = reliable scheduled working days in them; split at salary changes; applies to partial schedules, joiners, leavers, absence, unpaid leave and payout; never a full salary against a partial denominator | — | R7 (§19.3) |
| D16 | Monthly-paid employees without a work schedule: unpaid leave by Calendar-day Proration; no schedule required or invented; no division by zero; classification unchanged; the two prorations stay distinct | D17 | R7 (§19.3) |
| D17 | D16 only for employees whose requirement does not require attendance; required employees with a missing or unreliable schedule never fall back to D16; existing controls stay; no schedule created for leave; no classification change | — | R7 |
| D18 | Not-required leaver without a schedule: the leave settlement is held for HR/Payroll review, pending; never paid automatically, forfeited, erased or zeroed; balance and full history kept; the entitlement is not cancelled | D19–D21 | R6b, R7 |
| D19 | The `Pay Out` / `Forfeit` policy stays configurable per business in Business Settings, never removed or changed globally; `Forfeit` never overrides a D18 hold; after release the configured policy applies; `Forfeit` never converted into `Pay Out` | D21 (which policy version) | R6b |
| D20 | Release of a held settlement only after all of: (1) a reliable payout calculation for not-required employees formally approved; (2) HR review of employment details and balance; (3) Payroll approval of the amount; (4) the configured policy applied. Until then: balance preserved, pending, not paid, not forfeited or erased, full accrual, hold, review and settlement history kept | D21, D23 | R6b, R7 |
| D21 | The applicable policy for a held settlement is the business's policy **in force on the employment end date**, captured as an **immutable snapshot** (policy, its effective date, the business); a later settings change never changes the held settlement; on release the snapshotted policy is applied; `Forfeit` is never converted into `Pay Out`; no settings change silently rewrites an existing termination settlement | — | R6b (§19.3 OT9, §19.6) |
| D22 | Leaver required to attend with no scheduled working day in the final Payroll Period: the daily rate is calculated from a **reference period**, the last preceding reliable Payroll Period in which the employee had scheduled working days; the settlement record preserves the reference period and the rate used; never Calendar-day Proration for required employees; no schedule invented or working days assumed; D16 / D17 unchanged | D24–D27 | R7 (§19.3) |
| D23 | The Super Admin controls permission assignment; HR review (`manage_employees`) and Payroll approval (`finalize_payroll`) of a held settlement may be granted to one person or to two; the system enforces the configured permissions only, with no mandatory two-person rule; no new permission, permission model unchanged | — | R6b, R7 (§19.3 OT9) |
| D24 | D22 applies when there is no reliably scheduled working day within the **actual employment dates** of the final Payroll Period; scheduled days after the employment end date do not count | — | R7 (§19.3) |
| D25 | No preceding reliable Payroll Period with scheduled working days: the termination leave settlement stays **pending HR/Payroll review**; never paid, forfeited, zeroed or silently discarded | — (resolution: Q55) | R6b (case), R7 (§19.3) |
| D26 | The D22 daily rate uses the salary in force on the **employment end date**, not the reference period's salary | — | R7 (§19.3) |
| D27 | A preceding Payroll Period is reliable if it contains **at least one reliably scheduled working day**; the rate uses **only the reliably scheduled dates**; unscheduled dates are never working days; no schedule invented | — | R7 (§19.3) |

**Three separate historical facts of a held settlement** (D21 says they must not be confused):

| Fact | What it records | Source | Written |
|---|---|---|---|
| Leave-balance snapshot | the balance in days as of the employment end date (§18.10.2 K52) | WF leave ledger | when the hold is created |
| Termination-policy snapshot | `Pay Out` or `Forfeit`, the policy version's effective date and id, the business id (D21) | WF leave policy (Business Settings) | when the hold is created, never updated |
| Salary basis | not captured: the payout calculation is not approved (D20 (1)); salary profiles stay effective-dated and immutable, so the approved calculation can read them later | AP salary profiles | — |

**D22 reference rate** (a payout line, not a held settlement; D24–D27): the line records the reference Payroll
Period, the salary in force on the employment end date (D26), the reliably scheduled dates used (D27), and the
daily rate with its inputs (§19.3, D22 application). Without a reference period the settlement stays pending
HR/Payroll review (D25).

### 19.2 Question register

**Closed:** Q1–Q54. The full mapping from question to decision is §4.1 (Q51 → D21 added in revision 14;
Q52 → D22 and Q53 → D23 in revision 15; Q54 → D24–D27 in revision 16; the earlier text of closed questions is
kept in §5). Q5–Q8,
Q13, Q14, Q43 and Q45 (a)(b)(c)(e)(f)(g)(h) are technical decisions **[T]** (§18.1), not owner questions.

**Genuine owner decisions still open** (each is a business policy that no approved rule settles):

| ID | Decision needed | Why existing approvals cannot settle it | Recommendation and consequence | Blocks |
|---|---|---|---|---|
| **Q55** (from D25) | How a D25 pending settlement (leaver required to attend, no preceding reliable Payroll Period with scheduled working days) is eventually resolved: whether review steps like D20 (2) and (3) apply, and on which payout basis | D25 keeps the case pending HR/Payroll review but defines no resolution; D20 covers only not-required leavers (D18); a payout basis without a reference period would be a new pricing rule | **No recommendation.** Until decided, the case stays pending and listed for HR/Payroll review; nothing is paid, forfeited, zeroed or discarded (D25); the final payroll is finalized without the payout line (§18.10.2 K53) | Nothing: R7 builds the pending case; only its resolution waits |

**Approval gates that are not questions** (§19.12): owner approval of this plan (R1; given on 2026-11-10, revision
18); the R7.0 design (§19.4,
with its approval items A1–A6); the G1 design (§19.5, approval items G-A1–G-A6); the formal approval of the payout
calculation for not-required employees (D20 (1)); each phase's implementation authorisation.

### 19.3 Technical decisions OT1–OT9 **[T]**

**Common definitions** (used by OT2–OT8; dates in the business time zone):

```
P          = the Payroll Period = its calendar month [period_start, period_end]; N = its calendar days
W          = the employment window inside P: [max(period_start, employment start),
             min(period_end, employment_ended_on)]                                        (Q5 [T])
req(d)     = the attendance requirement in force on date d, read from the effective-dated
             history, never the users cache                                              (A3, L4, K48)
p(d)       = the salary profile in force on d (Salary::ProfileTimeline segment)
A(S, p)    = the salary BasicSalaryCalculator attributes to the date set S at profile p, exact
             (calendar rule: base(p) × |S| ÷ N; a starter: the starter working-days share)  (OT3)

Scheduled-day basis — dates with req(d) = required (D5 (b), L28, D15):
  Es       = dates of W with req = required and a reliable schedule (D12); C / L9 (2) blocked dates excluded
  SWD(Es)  = scheduled working days in Es, rest days excluded, holidays per the D11 setting
  rate_s(d)= A(Es, p(d)) ÷ SWD(Es)                                                     (OT2 reading ii)

Calendar-day basis — dates with req(d) = not required, monthly-paid (D16, D17):
  Ec       = dates of W with req = not required
  rate_c(d)= A(Ec ∩ seg(d), p(d)) ÷ |Ec ∩ seg(d)|   (calendar rule: = base(p(d)) ÷ N)        (OT4, OT5)

deduction line = Σ rate(d) over the counted dates, exact, rounded once to cents half up      (OT7)
cap            = a basis's deductions never exceed A of its eligible dates                    (D15)
fully eligible = Es = P, no salary change → rate_s = monthly salary ÷ SWD(P): exactly D5 (b) / L28
```

| # | Question | Approved rule it rests on | Evidence | Alternatives (trade-off) | Decision | Status |
|---|---|---|---|---|---|---|
| OT1 | Payout for a required leaver with no reliable scheduled working day in the final period's window | D6, D13, D15, D17 | §18.8.2 K31 | (a) a rate from another period; (b) Calendar-day Proration; (c) hold. (a) and (b) are new pricing rules; (b) is forbidden by D17 | **Not resolvable technically; decided by the owner as D22** (revision 15): alternative (a), a reference period; never (b). Details D24–D27; (c) only where no reference period exists (D25) | **Decided (D22, D24–D27)** |
| OT2 | Splitting at salary changes | D5 (b), L28, D15 | §18.8.3 | Reading (i) (each segment's salary ÷ its own scheduled days) changes a fully eligible period with a mid-period salary change, contradicting D5 (b); reading (ii) reproduces D5 (b) / L28 when Es = P and D15 when the salary is constant | Reading (ii): `rate_s(d) = A(Es, p(d)) ÷ SWD(Es)` | **Resolved [T]** |
| OT3 | Attribution basis of the numerator | D15 ("salary actually attributable") | `BasicSalaryCalculator` | A separate proration would let a deduction exceed what payroll pays | Reuse `BasicSalaryCalculator`'s portions exactly (calendar rule, or the starter rule for a first profile starting after the 1st); no second proration | **Resolved [T]** |
| OT4 | Calendar-day denominator; holidays | D16 ("calendar-day"), L28 (no fixed 30) | Periods are calendar months (§19.0) | Calendar month vs payroll period: identical here; excluding holidays would turn calendar days into a schedule, which D16 does not ask for and D11 confines to scheduled days | Denominator = calendar days of the Payroll Period (N); inside a partial window, the calendar days of `Ec ∩ seg(d)`; holidays are **not** excluded | **Resolved [T]**. If a business ever has non-calendar-month periods, this needs review (none exist) |
| OT5 | Salary changes inside the period | L28, D15, D16 | `Salary::ProfileTimeline` | Pricing all dates at one profile would ignore L28's per-date rule | Each leave date priced at its own profile through `rate_c(d)`; calculation split at profile boundaries | **Resolved [T]** |
| OT6 | Partial employment and mixed periods (joiners, leavers, a requirement change inside the period) | D15, D16, D17, A3, K48 | §18.10.2 K48 | One method for the whole period would price some dates by the wrong rule | Each date belongs to exactly one basis by `req(d)`; dates outside W are never priced; required dates without a reliable schedule follow C / D12 / L32 (never calendar-day, D17); the not-required part uses Ec | **Resolved [T]** |
| OT7 | Rounding and precision | CLAUDE.md money rules | `BasicSalaryCalculator::ROUNDING` | Rounding per date drifts; floats are forbidden | Exact `Rational` per date; one rounding per deduction or payout line, to cents, half up; the breakdown stores the inputs (dates, numerator, denominator, profile ids) as decimal strings; leave days stay `decimal(6,2)` | **Resolved [T]** |
| OT8 | Which leave days count on the calendar-day basis | D16 (calendar basis), OT4 | R6b models leave by date | Counting only weekdays would invent a schedule (D16) | Every calendar date of approved unpaid leave inside Ec counts once, weekends and holidays included, consistent with the OT4 denominator; whole days, as R6b models leave dates | **Resolved [T]** |
| OT9 | Held-settlement steps: permissions, same person, rejection, post-lock payment | D18–D21, L21, L30 | §19.0 (SelfApproval, #117 payer) | See below | Resolved; the same-person point is decided by the owner as D23 | **Resolved [T]**; same person: D23 |

**OT9 design [T]** (held termination settlement, D18–D21):

```
created  — at termination of a not-required employee with no schedule at the end (R6b, in the
           termination transaction): leave-balance snapshot + termination-policy snapshot (D21);
           status pending; no ledger entry (K52); listed on the HR/Payroll review report
hr_reviewed      — HR (manage_employees, D23; inside EmployeeScope; precedent L30) records the review of
                   employment details and balance, with a note                      D20 (2)
payroll_approved — Payroll (finalize_payroll, D23; own business) approves the amount: under Pay Out the
                   amount computed by the formally approved calculation; under Forfeit the days to
                   forfeit. Refused while no calculation is approved (D20 (1)), even under Forfeit
                   (§18.11.2 K63). The HR reviewer may also approve when the configured
                   permissions allow it (D23); no two-person rule                   D20 (3)
released         — in the same transaction as payroll_approved, once (1)–(3) hold: the snapshotted
                   policy is applied (D21): Pay Out → one termination_settlement ledger entry and a
                   payable AP payout record; Forfeit → one forfeiture ledger entry       D20 (4)
returned         — HR or Payroll returns the case with a mandatory reason → back to pending; the step
                   history is kept; a new review is a new step row (no maximum, as D8 (c))
paid (Pay Out)   — pay_payroll records the payment of the payout record (who, when, note), the
                   #117 ReleasedSalaryPayer pattern; the final payroll period is normally locked by
                   then and is never reopened for it (L21 precedent)
```

* **Invariants:** one live case per employee termination (partial unique index); steps append-only; the two
  snapshots never updated (model guard plus no update path); exactly one ledger entry at release; no expiry,
  accrual or forfeiture entry while pending (K52); every step `log_audit!` (the case record is the evidence of the
  entitlement, BUG-003 fail-closed list); locks: the employee's leave advisory lock (G6), then the case row
  `FOR UPDATE`, state re-checked.
* **Domains:** WF owns the case, both snapshots, the HR step and the ledger entries; AP owns the Payroll approval
  record and the payout payment record. AP calls a WF-defined contract (`Leave::SettlementRelease`, AP → WF is the
  allowed direction) to apply the snapshotted policy; WF never references AP.
* **Payout cost (Pay Out):** reported as a payroll cost of the employee's final Payroll Period, labelled
  "late settlement", Provisional until paid (F); no insurance effect (insurance comes from the insurance profile,
  §19.0); no Finance expense is created, as for salaries today.
* **Acceptance:** release refused for each missing condition; release under `Forfeit` writes one forfeiture entry
  and never a payout; a settings change after the end date changes nothing (D21); one actor holding both
  permissions may record (2) and (3), each as its own step row with its actor (D23);
  returned cases keep history; concurrent releases → one.
* **Tests:** one spec per missing D20 condition; D21 snapshot unchanged after `Forfeit` → `Pay Out` and the
  reverse; `Forfeit` never produces a payout record; two-thread release → one ledger entry; cross-business case id →
  not found; actor without `manage_employees` / `finalize_payroll` refused; an HR reviewer who also holds
  `finalize_payroll` may approve (D23), one without it is refused at (3);
  audit write failure → whole step rolled back.

**D22 application** (leaver required to attend; rules D22, D24–D27 **[A]**, mechanics **[T]**):

* **Applies when (D22, D24):** the employee is required to attend (`req(d)` from the history) and has no reliably
  scheduled working day within the actual employment dates of the final Payroll Period (Es of the final period is
  empty); scheduled days after the employment end date do not count. **[T]** Only under `Pay Out`: under `Forfeit`
  the recorded forfeiture entry needs no rate (D6). Not-required leavers without a schedule stay under D18–D21.
* **Reference period (D22, D27):** the last Payroll Period before the final one that contains at least one reliably
  scheduled working day for the employee. Unscheduled dates are never treated as working days, no schedule is
  estimated, and Calendar-day Proration is never used (D17).
* **Rate (D26, D27; formula [T], with the §19.3 definitions):**

```
Es_ref   = the reliably scheduled dates of the reference period (its Es; D27)
p_end    = the salary profile in force on the employment end date (D26)
rate_ref = A(Es_ref, p_end) ÷ SWD(Es_ref)                 (D13, D15: same dates in both)
payout   = remaining eligible days × rate_ref, rounded once to cents half up      (D6, OT7)
```

* **Record (D22–D27):** the payout line's breakdown stores, as decimal strings (OT7): the reference Payroll Period
  id; the salary profile id and monthly salary in force on the employment end date; the reliably scheduled dates
  used and SWD(Es_ref); the numerator A(Es_ref, p_end) and the reference period's calendar days; the daily rate; the
  remaining days and the payout amount. The line stays a separate Final Payroll line (D6).
* **No reference period (D25):** the termination leave settlement stays pending HR/Payroll review: no payout line;
  a settlement case (reason `required_no_reference_period`) listed on the HR/Payroll review report; the balance is
  never paid, forfeited, zeroed or discarded; the final payroll is finalized without that line (§18.10.2 K53). How
  such a case is eventually resolved is Q55.
* **Acceptance and tests:** final day a rest day with scheduled days only after the end date → reference-period
  rate (D24); salary raised after the reference period → the end-date salary is used (D26); reference period partly
  unscheduled → only its reliably scheduled dates in numerator and denominator (D27); the breakdown reproduces the
  amount; a required leaver never gets `rate_c`; a not-required leaver without a schedule is still held (D18); no
  reference period → pending case, no payout line, balance unchanged (D25).

### 19.4 R7.0 — held-employee payroll design (approval-ready, **not approved**)

Scope: the employee-level finalization hold that L32 requires and D7 approves in principle. It is distinct from
#117's Salary Payment Hold, which blocks **payment** of an already finalized amount; R7.0 blocks
**finalization** of an amount that cannot yet be calculated reliably.

**19.4.1 Interpretation of D7's "within the same Payroll Period" [T].** Payroll Periods are calendar months
finalized after the month ends (§19.0), so the phrase cannot mean "before the month's last day". It means the
held entry stays an entry **of its original Payroll Period**: it is never moved to a later period, and its late
finalization and payment are recorded against that period. A later period of the same employee is calculated
independently and is never blocked by the earlier hold.

**19.4.2 Derived employee-level states** (derived from data shape, never a stored status flag):

```
calculated ──(period finalized, no live hold)──────────────────────────▶ finalized_with_period
    │                                                                         │
    │ R7 flags the entry (L32, C per-employee where approved)                 │ period paid,
    ▼                                                                         ▼ no withholding
held ──(period finalized without it)──▶ held_after_period_finalized      paid_with_period
    │  data fixed → entry recalculated (allowed while held, 19.4.4)
    ▼
in_review ──(reviewer returns, reason)──▶ returned ──(fixed, recalculated)──▶ in_review
    │ reviewed (digest of the reviewed figures)
    ▼
released ──(digest unchanged, under the period lock)──▶ late_finalized
                                                              │ period already paid, or later paid
                                                              ▼
                                                        payment_pending ──(pay_payroll records)──▶ paid_late
```

| State | Defined by |
|---|---|
| calculated | entry, period not locked, no live hold |
| held | live `payroll_entry_finalization_holds` row (released_at null) |
| in_review / returned | latest `payroll_entry_hold_reviews` step for the live hold: `submitted` / `returned` |
| released | hold `released_at` set |
| late_finalized | live `payroll_entry_late_finalizations` row |
| payment_pending | late finalization without `disbursed_at`, or period `finalized` |
| paid_late | late finalization with `disbursed_at` |
| finalized_with_period / paid_with_period | period locked, the entry never had a live hold at finalization |

Calculation, finalization, approval and payment stay four separate events: recalculation writes figures;
review approves a digest; late finalization freezes the figures and creates the financial effects; payment
records the disbursement.

**19.4.3 Data model** (all AP-owned except the expense column; all additive):

| Table / column | Columns and constraints |
|---|---|
| `payroll_entry_finalization_holds` | `business_id`, `payroll_period_id`, `payroll_entry_id`, `user_id`, `reason_key` (`unpaid_leave_unpriceable` (L32), `required_without_schedule` (C, only if the R7.0 approval extends per-employee holds to C; see A3)), `reason_details` jsonb (dates), `created_at`, `created_by_id`, `released_at`, `released_by_id`, `release_reason`; partial unique index one live hold per entry (`released_at IS NULL`); check `(released_at IS NULL) = (released_by_id IS NULL)`; never deleted |
| `payroll_entry_hold_reviews` | append-only steps: `hold_id`, `kind` (`submitted` / `returned` / `approved`), `actor_id`, `reason`, `figures_digest` (the `financial_snapshot` digest reviewed), `created_at` |
| `payroll_entry_late_finalizations` | `business_id`, `payroll_period_id`, `payroll_entry_id`, `hold_id`, `finalized_at`, `finalized_by_id`, `figures` jsonb (the frozen `financial_snapshot`), `disbursed_at`, `disbursed_by_id`, `disbursement_note`, `voided_at`, `voided_by_id`, `void_reason`; partial unique index one live row per entry (`voided_at IS NULL`); check constraints as `salary_payment_withholdings` (disbursement complete, void complete, not both) |
| `expenses.source_payroll_entry_id` (FS) | nullable FK; partial unique index `(source_payroll_entry_id) WHERE source_payroll_entry_id IS NOT NULL AND voided_at IS NULL`; a supplementary expense sets `source_payroll_period_id` **NULL** so the existing per-period index is untouched; a check constraint forbids both sources set at once |

**19.4.4 Service boundaries and transactions** (lock order request → period → entry, as everywhere):

| Service (AP unless noted) | Transaction and locks | Effect |
|---|---|---|
| `Payroll::EntryHoldFlagger` (called by R7's calculation) | inside the recalculation, under the period lock | creates or keeps one live hold when the entry is flagged; never releases one |
| `PayrollEntry` predicate | — | `frozen_for_edit?` = period locked **and** no live hold; the one exception that lets a held entry be recalculated while the period is finalized; `salary_breakdown_frozen_while_locked` uses it |
| `Payroll::Approver` (changed) | unchanged locks | finalizes every entry except live-held ones; `period_finalized` payload excludes them; "N held" on the period page; the `CentralReview` digest excludes held entries consistently; `paid` excludes held and late-unpaid entries from advance settlement and payment |
| `Payroll::HeldEntryReviewer` | period lock → hold row lock | `submitted` (after a recalculation shows no flag), `returned` (reason), `approved` (records the digest) |
| `Payroll::HeldEntryFinalizer` | period lock → hold row lock → entry; digest re-checked | sets `released_at`, writes the late finalization, calls the contract `entry_finalized(period:, entry_id:, actor:, costs:)`; refused if the digest changed since approval |
| `Finance::PayrollInsuranceExpense` (FS, extended) | inside the caller's transaction | records one supplementary insurance expense for the entry (fully allocated per R10 rules), `expense_date = period_end`, linked by `source_payroll_entry_id` |
| `Payroll::LateEntryPayer` | period lock → late finalization row lock | records the disbursement (the `ReleasedSalaryPayer` pattern); refused while the period is not yet `paid` (the late entry is then paid with the period instead), while a #117 Salary Payment Hold is active, or twice |
| `Payroll::Reopener` (changed) | unchanged | `paid → finalized` refused when a late entry was disbursed; `finalized → branch_review_completed` voids live late finalizations and, through `period_reopened`, the period's and every supplementary expense; holds stay as they are |

**19.4.5 Financial event flow:**

```
finalize period          → period insurance expense = Σ insured, non-held entries   (period_finalized)
late-finalize entry E    → supplementary insurance expense for E only               (entry_finalized)
pay period               → advances settled and payment recorded for non-held entries; #117 withholding
pay late entry E         → E's advances settled, disbursement recorded on its late finalization row
reopen finalized period  → void the period expense + every supplementary expense + live late finalizations
reconciliation           → Σ entries of the period = finalized_with_period + late_finalized + held (Provisional);
                           insurance: period expense + Σ supplementary = Σ employer insurance of finalized entries
```

Accounting consequence of `expense_date = period_end` for the supplementary expense: the cost belongs to the month it
was earned (accrual), so a Finance report for that month changes when a held entry is late-finalized. This is
intended: until then the held cost was shown as Provisional (F, D7), never omitted. No duplicate is possible: the
period expense never contains a held entry, and each entry has at most one live supplementary expense.

**19.4.6 Provisional reporting:**

| View | Rule |
|---|---|
| Payroll review (period page) | held entries listed with reason, state and figures labelled **Provisional**; period totals shown as finalized + held (Provisional) separately |
| Branch reports | the held employee's cost in a separate **Provisional** line; for central / floating staff inside the D2 aggregate, the aggregate is split into finalized and Provisional amounts; no names (D2, I) |
| Business reports | finalized, Provisional (held) and paid shown in separate columns; never summed without labels (F) |
| Finance reconciliation | the period's insurance expense plus supplementary expenses reconcile to Σ employer insurance of finalized entries; held entries' insurance listed as Provisional, with no expense yet |
| Employee self-service | a held entry is not employee-visible until late-finalized (`employee_visible` extended) |
| Bank CSV export | excludes held and late-finalized-unpaid entries, as it excludes #117 withheld entries |

**19.4.7 Authorization and audit:**

| Action | Permission (existing unless noted) | Identity rule | Audit |
|---|---|---|---|
| Hold created | system, during calculation by the triggering actor | — | `payroll_entry_hold_created` (`log_audit!`) + `PayrollAuditLog` |
| Submit for review / return | `complete_branch_review`; for floating and central employees the central reviewer (`complete_central_review?`) | not on one's own entry (A2) | `payroll_entry_hold_review_submitted` / `_returned` with reason |
| Approve review | `approve_payroll_items` | not on one's own entry; not the submitter (A2) | `payroll_entry_hold_review_approved` with digest |
| Late finalization | `finalize_payroll` | not on one's own entry (A2) | `payroll_entry_late_finalized` + `PayrollAuditLog` |
| Late payment | `pay_payroll` | not on one's own entry (A2) | `payroll_entry_late_paid` (`log_audit!`) |
| Reopen | `reopen_payroll` (unchanged) | unchanged | existing reopen audit, plus voided ids |

Every service loads records by id inside `actor.business` and re-checks state under its locks; policies use
`can?`, never `owner?`; cross-business ids raise not found.

**19.4.8 Failure recovery and idempotency:** every operation is one transaction; a failure rolls back the hold
step, the late finalization and its expense together. Double submissions: unique indexes plus state re-checks
under the locks return "already done". No background job is needed; a daily read-only aging check lists holds
older than A4's threshold on the period page and the review report (no notification system exists; the audit-failure
dashboard of R3.1 is for audit events only).

**19.4.9 API / UI:** period page "Held employees" panel with state, reason and age; entry page actions per state
(submit, return, approve, late-finalize, pay late) each with a confirmation and mandatory reason where it is a
reversal; the mobile API exposes held entries to employees only after late finalization. EN + AR keys for every
string.

**19.4.10 Acceptance criteria:** a period with one held entry finalizes every other entry, and its insurance
expense excludes the held one; the held entry is recalculable while the others are frozen; late finalization
happens once under two concurrent attempts; one supplementary expense per entry; reopen voids everything derived;
a paid period with a disbursed late entry cannot be reopened to `finalized`; the held entry is invisible to the
employee and absent from the bank CSV until late-finalized; reports never add Provisional into finalized totals;
**parity: a period without holds produces exactly today's records**.

**19.4.11 Test matrix:**

| Area | Tests |
|---|---|
| Lifecycle | each transition; each refused transition (wrong state, digest changed, period not paid for late payment) |
| Concurrency | two-thread late finalization → one; finalize period vs flagger; late payment vs reopen |
| Money | insurance period + supplementary = Σ finalized; advances settled once per entry; no float |
| Authorization (negative) | each action without its permission; cross-business id; acting on one's own entry; approver = submitter |
| Contract | `entry_finalized` probe; registration check of `OPERATIONS`; Finance reads no payroll entries (boundary spec) |
| #117 interaction | late payment refused while a Salary Payment Hold is active; withholding of a late entry when the period is paid after release |
| Reporting | Provisional lines and columns; D2 aggregate split; employee visibility |
| Parity | full regression of periods without holds |

**19.4.12 Migration and rollout:** additive tables and the nullable expense column with its index, in R10, mapped
in module-boundaries §10–§11 in the same commit; no backfill (no holds exist). The flagger is switched on with R7,
after R11 can show Provisional held costs (§19.10). Rollback: before any hold exists, revert the code; afterwards,
disabling the flagger stops new holds while existing ones complete through the same services.

**R7.0 approval items** (the owner approves these with the design; recommendations shown):

| # | Item | Recommendation |
|---|---|---|
| A1 | "Within the same Payroll Period" read as "stays in its original period" (19.4.1) | Approve |
| A2 | Nobody acts on their own held entry; the review approver differs from the submitter (precedent: `SalaryPaymentHoldPolicy` excludes the actor's own record); owners included | Approve |
| A3 | Whether blocker C (required employee without assignment and schedule) also becomes a per-employee hold, or keeps blocking the whole period as approved in C | Keep C period-wide (as approved); per-employee holds only for L32 |
| A4 | No deadline: a hold never expires or auto-releases; aging shown after 30 days | Approve; the 30-day threshold is configurable |
| A5 | Supplementary expense dated `period_end` (accrual) | Approve |
| A6 | Permissions as in 19.4.7 (no new permission) | Approve |

### 19.5 G1 — Platform Operator design (approval-ready, **not approved**)

**19.5.1 Identity and separation.** A Platform Operator is **not** a `User`: an OA-owned `PlatformOperator` model
with its own table and its own Devise scope. It has no `business_id`, no `PermissionRole`, no owner relation, and
cannot sign in to any business page; a `User`, including a business owner (Super Admin, D1 (3)), cannot sign in to
the platform area. Nothing in `can?`, `owner?`, `ApplicationPolicy` or `Admin::` changes. There is no universal
bypass: the operator reaches only the platform controllers below.

| Table (OA) | Columns |
|---|---|
| `platform_operators` | `email` (unique), `encrypted_password`, `otp_secret` (Active Record encryption), `otp_required` (always true), `consumed_timestep`, `failed_attempts`, `locked_at`, `unlock_token`, `sign_in_count`, `current_sign_in_at`, `last_sign_in_at`, `current_sign_in_ip`, `last_sign_in_ip`, `session_token` (rotated on revocation), `granted_at`, `granted_by` (text: the granting operator or console identity), `revoked_at`, `revoke_reason` |
| `platform_operator_recovery_codes` | `platform_operator_id`, `code_digest`, `used_at`; ten single-use codes |
| `platform_operator_events` | append-only: `platform_operator_id` (nullable for an unknown e-mail), `action`, `target_type`, `target_id`, `business_id` (of the target, when any), `ip`, `user_agent`, `request_id`, `details` jsonb, `created_at`; no update path, model refuses updates and deletes |

**19.5.2 Authentication and recovery:**
* Devise modules: `database_authenticatable`, `lockable` (5 failures, unlock after 1 hour or by another
  operator), `timeoutable` (15 minutes idle), `trackable`; **not** `registerable`, `recoverable` or
  `rememberable`. Password at least 14 characters.
* **MFA mandatory:** TOTP at every sign-in, with single-use recovery codes. No MFA exists in the repository today, so
  it needs a new, audited dependency (G-A1) and Active Record encryption keys in credentials (G-A2).
* **Account recovery:** no e-mail reset. A lost password or device is recovered by **another** operator through an
  audited console task that rotates the password and the TOTP secret; the operator re-enrols at next sign-in.
* **Session:** `session_token` stored in the session and compared on every request; rotation signs out every
  session at once. The platform area is served under its own host (G-A3), so its cookie never coexists with a
  business session in the same cookie jar; signing in to one scope signs out the other.

**19.5.3 Lifecycle:** granted only by an audited console task (`platform:operators:grant`, run by the platform
team, recording who ran it), never through the UI and never by a business user; revoked by `platform:operators:revoke`
or by another operator in the UI (`revoked_at`, session rotation, immediate effect); a periodic listing of active
operators for review. Bootstrap: the first operator by the console task, recorded as such.

**19.5.4 Authorization (allow-list):**

| Capability | Allowed | Data shown |
|---|---|---|
| Audit-failure dashboard (all businesses) | yes | event id, business name and id, auditable type and id, action name, created / last attempt / next attempt times, attempt count, consecutive failures, last error class and a scrubbed message, resolution state |
| Event payload (`changes_json`, `metadata`) | **no** | hidden: it can contain salaries and personal data |
| Retry Now | yes, one event at a time | result only |
| Users, employees, payroll, salary, leave, attendance, expenses, custody, inventory, settings, reports | **no** | none |
| Revoke another operator, unlock | yes | operator list |

`Platform::BaseController < ActionController::Base` (not `ApplicationController`, so no business hooks), with
`authenticate_platform_operator!`, an `after_action :verify_authorized`, its own policies (`Platform::*Policy`,
`pundit_user = current_platform_operator`) and its own layout. The unscoped cross-business query for audit events
exists only in `Platform::PendingAuditEventsQuery`, the single place allowed to read across businesses; a boundary
spec fails on any other unscoped read or on any `Platform::` file naming a business-domain model other than
`Business` (name only).

**19.5.5 Retry Now:** runs the G10 delivery service (`FOR UPDATE NOWAIT`, exactly-once insert); the delivered
`AuditLog` keeps its original business actor and business; the operator is recorded in the attempt log and in
`platform_operator_events`; a busy record returns "retry in progress"; rate-limited per operator.

**19.5.6 Audit, monitoring and alerts:** every operator request that reads or acts writes a
`platform_operator_events` row (sign-in success, failure, MFA failure, lockout, dashboard view, event view, retry,
revoke, unlock, sign-out, timeout). Alerts (Rails error reporting, the channel the app already uses): repeated sign-in
or MFA failures, lockouts, a grant or revocation, retries above a threshold. Business users never see operator
records.

**19.5.7 Emergency access:** server console access (`docker compose exec web ./bin/rails console`) is the break-glass
path; it is outside application authorization by nature, so its use is governed by the platform team's runbook,
which requires a written reason and is reviewed afterwards. The application adds no hidden bypass.

**19.5.8 Tests:** an operator gets no response other than not found / redirect on every business route (owner
routes, admin, API, finance, payroll); a business user, owners included, gets not found on `/platform`; the operator
sees events of two businesses with payloads hidden; only an operator can Retry Now; two concurrent retries → one
delivery; lockout after 5 failures; MFA required; session rotation signs out; revoked operator refused at once;
boundary spec for unscoped queries and model references; Brakeman clean.

**19.5.9 Domains and phase:** OA owns `platform_operators`, recovery codes, `platform_operator_events` and the
`Platform::` controllers' authorization; Infrastructure (Audit) owns `pending_audit_events` and the delivery service;
mapped in module-boundaries §10–§11 and §16 in the same commit (G7). Phase R3.5, after R3.1.

**G1 approval items:**

| # | Item | Recommendation |
|---|---|---|
| G-A1 | New MFA dependency (TOTP library, plus bundler-audit) | Approve a maintained TOTP gem |
| G-A2 | Active Record encryption keys in credentials | Approve |
| G-A3 | A separate host for the platform area | Approve; fallback: same host, scope-exclusive sign-in |
| G-A4 | Allow-list in 19.5.4, payloads hidden | Approve |
| G-A5 | Recovery only by another operator through the console | Approve |
| G-A6 | Retention of `platform_operator_events`: kept indefinitely | Approve |

### 19.6 Domain ownership map (consolidated)

| Domain | Owns (new in this plan) | Reads | Contracts |
|---|---|---|---|
| Workforce | `employee_attendance_requirements` and the cache; assignment `working_weekdays`, `ScheduleChanger`; Holiday Calendar; leave types, policy (incl. the `Pay Out` / `Forfeit` setting), routing, requests, batches, ledger; held termination settlement cases with both D21 / K52 snapshots; `employment_ended_on`; requirement and leave jobs | OA (branches, accounts) | defines: requirement read API and validation contract (L1), invariant lock helper, approved-leave read API, `Leave::SettlementRelease` |
| Attendance & Payroll | `Payroll::ScheduledDays`, rates (§19.3), absence and leave effects, Parity Report, Historical Violations and corrections, finalization holds, hold reviews, late finalizations, payout approval and payment records | WF read APIs; salary profiles (own) | implements the L1 contract; defines `Payroll::FinalizationEffects` (extended once in R10) |
| Finance & Sales | Cost Allocation Rules and versions, snapshots, expense validation, `expenses.source_payroll_entry_id` and supplementary expenses | payload data only | implements `FinalizationEffects` |
| Organization & Access | new permissions (G5), presets, Finance Approver designations, `platform_operators`, recovery codes, `platform_operator_events` | — | `OrganizationAccess::Accounts` (D1 module-boundaries) |
| Reporting | read-only: snapshot-first reports, Provisional labelling, D2 aggregate | all | none; no writes |
| Infrastructure (Audit) | `pending_audit_events`, attempts, delivery service, sweeper, dashboards | — | used by every domain |

No Scheduling or Attendance domain is created. Every new table is mapped in the same commit as its migration (G7).

### 19.7 Consolidated calculation and lifecycle rules (quick reference)

| Topic | Final rule | Source |
|---|---|---|
| Absence (monthly) | `Σ rate_s(d)` over absent scheduled days in Es; Parity Report first | D5 (b), D11, D12, D15, §19.3 |
| Unpaid leave, required | `Σ rate_s(d)` over unpaid-leave workdays in Es; missing denominator → Flagged for Review, per-employee hold | L28, L32, D15, R7.0 |
| Unpaid leave, not required | `Σ rate_c(d)` over calendar dates of approved unpaid leave in Ec | D16, D17, OT4–OT8 |
| Daily-paid | pay = rate × approved attendance days; unpaid leave only, not absence | A9, L6, D8 (a) |
| Same date | never deducted as absence and unpaid leave twice | D5 (b) |
| Payout, scheduled leaver | remaining days × `rate_s(employment end date)` over the final period's Es; separate Final Payroll line | D6, D13, D15, K21 |
| Payout, required leaver, no scheduled day | remaining days × `rate_ref` (end-date salary over the reference period's reliably scheduled dates), recorded with the line; never `rate_c`; no reference period: pending HR/Payroll review, never paid, forfeited or zeroed (D25) | D22, D24–D27, D17 |
| Settlement, not-required leaver, no schedule | held; released only under D20 with the D21 snapshot; the two review steps by the configured permissions, one person or two (D23) | D18–D21, D23, OT9 |
| Settlement, other leavers | per the business setting at termination: payout line or recorded forfeiture | D6, D19 |
| Leave balance | append-only two-decimal ledger, tiers, anniversary year, FEFO batches, carry-over cap, 31 March expiry, accrual during unpaid leave, never negative | L26, L31, D8 (b), D14 |
| Rounding | exact per date, once per line, cents half up | OT7 |
| Business day | `BusinessDay.current(context: business)`, never `Date.current` | CLAUDE.md |

### 19.8 Risks and mitigations (consolidated; adds to §16)

| # | Risk | Mitigation |
|---|---|---|
| R-1 | Duplicate insurance cost between the period and a late entry | held entries excluded from `period_finalized`; one live supplementary expense per entry (unique index); reconciliation spec |
| R-2 | A held entry silently paid or shown as finalized | bank CSV, payment and employee visibility exclude it; Provisional labels; R11 before R7's flagger |
| R-3 | A held settlement eroded or rewritten | K52 balance snapshot, D21 policy snapshot, no ledger entry while pending, jobs skip held balances |
| R-4 | Wrong pricing basis for a date | `req(d)` from the history only; one basis per date; property spec over random requirement histories |
| R-5 | Contract changed twice | R10 before R7 (§19.10); `OPERATIONS` check |
| R-6 | Platform operator over-reach | allow-list, separate scope and host, boundary spec, payloads hidden, events log |
| R-7 | Self-approval through owner powers | identity checks on held entries, no owner exception (A2); held-settlement steps follow the configured permissions (D23) |
| R-8 | Rounding drift | one rounding per line; breakdown stores inputs |
| R-9 | Business-day drift in jobs | `BusinessDay.current`; idempotent natural keys |
| R-10 | Lock-order deadlocks | request → period → entry everywhere; no locks in loops (F-A7 precedent) |
| R-11 | Audit loss on financial evidence | `log_audit!` for holds, late finalizations, settlement steps (BUG-003 fail-closed) |
| R-12 | Leave settlements recorded before payroll can pay them | the termination-settlement writer is enabled with R7 (§19.10 R6b); until then leavers' balances stay and are listed, never paid or forfeited |
| R-13 | Reports change for a past month at late finalization | intended accrual effect, shown Provisional beforehand (A5) |
| R-14 | Existing `.to_f` in `EntryCalculator#resolve_insurance_snapshot` (money as float) | not changed by this plan; to be registered in `docs/quality/deferred-bugs.md` by its owner (deferred-bug policy) |
| R-15 | One person records both held-settlement steps (allowed by D23) | each step is its own append-only row with actor, time and note, written with `log_audit!`; who holds the permissions is the Super Admin's configuration |

### 19.9 Traceability matrix

| Decision | Architecture rule | Domain | Phase | Acceptance (§14 / §19) | Tests (§15 / §19) |
|---|---|---|---|---|---|
| D1 | deadline counter from R3.3 deploy; platform identity separate | WF; OA | R3.3, R5; R3.5 | Not Reviewed cut-off; §19.5 | deadline spec; G1 tests §19.5.8 |
| D2 | one aggregate label, no names | Reporting | R11 | R11 row | branch report privacy spec |
| D3 | one business-wide calendar | WF | R6 | R6 row | calendar specs |
| D4 | backdating refused from `under_review` | WF | R3.2 | R3.2 row | backdating spec per status |
| D5 | (a) overlap validation; (b) rate_s, Parity Report | WF; AP | R4; R7 | R4, R7 rows | overlap spec; D5 (b) specs, parity |
| D6 | payout line; never silent | WF; AP | R6b, R7 | R6b, R7 rows | payout line spec |
| D7 | per-entry hold, late finalization in the original period, Provisional | AP; FS; Reporting | R10, R7, R11 | §19.4.10 | §19.4.11 |
| D8 | (a) unpaid only; (b) expiry, FEFO; (c) resubmission chain | WF; AP | R6b; R3b | R6b, R3b rows | leave and correction specs |
| D9 | legacy exception counter from R4 deploy | WF; AP | R4, R7 | R7 row | deadline spec |
| D10 | R3.3 deploy = start | WF | R3.3 | R3.3 row | deadline spec |
| D11 | holiday setting on absence divisor | AP | R7 | R7 row | setting on/off |
| D12 | unscheduled portion not deducted, warning | AP | R7 | R7 row | partly unscheduled spec |
| D13 | payout at rate_s | AP | R7 | R7 row | payout rate spec |
| D14 | carry-over calendar year | WF | R6b | R6b row | 30 March carry-over spec |
| D15 | same eligible dates (§19.3) | AP | R7 | R7 row | joiner, leaver, partial specs; worked example |
| D16 | rate_c (§19.3) | AP | R7 | R7 row | central unpaid leave specs |
| D17 | basis by `req(d)` | AP (reads WF) | R7 | R7 row | required employees never D16 |
| D18 | held case, snapshots | WF; AP | R6b, R7 | §19.3 OT9 | OT9 tests |
| D19 | `Pay Out` / `Forfeit` kept; hold priority | WF | R6b | R6b row | Forfeit setting with hold |
| D20 | four release conditions | WF; AP | R6b, R7 | §19.3 OT9 | one spec per condition |
| D21 | immutable policy snapshot at the end date | WF | R6b | §19.3 OT9 | snapshot unchanged after settings change |
| D22 | reference-period rate, recorded with the payout line; never D16 for required employees | AP (reads WF) | R7 | §19.3 D22 application | reference period named in the breakdown; required never `rate_c`; no reference period held |
| D23 | configured permissions only; no two-person rule | WF; AP | R6b, R7 | §19.3 OT9 | one actor with both permissions records both steps; missing permission refused |
| D24 | only the employment dates of the final period count | AP (reads WF) | R7 | §19.3 D22 application | scheduled days after the end date ignored |
| D25 | no reference period → pending case, never silent | WF; AP | R6b, R7 | §19.3 D22 application | no payout line, balance unchanged |
| D26 | end-date salary in `rate_ref` | AP | R7 | §19.3 D22 application | salary change after the reference period |
| D27 | at least one reliably scheduled day; only those dates priced | AP (reads WF) | R7 | §19.3 D22 application | partly unscheduled reference period |

### 19.10 Implementation roadmap R0–R13 (supersedes the order in §13 and §18.4)

**Order change [T]:** R10 (contract extension and the R7.0 hold infrastructure) and R11 (Provisional reporting) now
come **before** R7. Reason: L32 lets the other employees finalize while one is held, which needs per-entry
finalization; G8 changes the Payroll → Finance contract only once; and F / D7 require held costs to show as
Provisional before any hold exists. R7's calculation is therefore deployed onto an infrastructure that can already
hold, finalize late and report. R12 and R13 follow R5 and can run in parallel.

**Order:** R0 → R1 → R2 → R3.1 → R3.2 → R3.4 → R3.3 → R3.5 (after G1 approval) → R3b → R4 → R5 → R6 → R6b → R8 → R9 →
(R7.0 approved) → R10 → R11 → R7 → R12 → R13.

Every phase: branch from current `main`; re-read the §19.0 evidence it depends on; focused specs plus
`spec/architecture` (full suite only with approval); `bin/rubocop`, Brakeman, bundler-audit; EN + AR keys; module
mapping of every new table in the same commit; no commit or merge without the owner's approval.

| Phase | Objective and scope | Prerequisites | Domain | Schema | Service / API / UI | Permissions | Audit | Acceptance and tests | Rollout, rollback | Completion gate |
|---|---|---|---|---|---|---|---|---|---|---|
| R0 | read-only production counts (§13) | an authorised operator | — | none | none | — | queries recorded | counts reviewed by the owner | read-only | counts in hand before R3.3 |
| R1 | `CLAUDE.md` and module-boundaries updates for implemented behaviour | owner approval of this plan | docs | none | none | — | — | review | revert docs | merged docs PR |
| R2 | `MoneySplitter` extraction | — | FS | none | refactor | — | unchanged | behaviour-preserving specs | revert | parity specs green |
| R3.1 | durable audit record, sweeper, attempt log, business dashboard | — | Infra; OA | `pending_audit_events`, attempts | delivery service, sweeper job (`recurring.yml`), dashboard | `monitor_audit_failures` | attempt log | G10 tests | supervisor restart; disable sweeper | exactly-once proven under concurrency |
| R3.2 | requirement history, change service, cache, creation selection, service-date correction | — | WF | `employee_attendance_requirements`, `employment_ended_on` (Q5) | WF services, roll-forward job, UI | `manage_employees` | every change | §14 R3 rows | additive; feature off until R3.3 | history append-only, business-day specs |
| R3.3 | backfill and HR exception list | R0, R3.2 | WF | data only | backfill task, reports | `manage_employees` | each row | §14 | dry run first; re-runnable | counts match R0; starts the D1 count |
| R3.4 | daily-paid invariant both directions | R3.1, R3.2 | AP + WF | none | contract, lock helper | existing | rejected attempts (L8, L14) | §14, §15 | additive | both directions rejected, audit durable |
| R3.5 | Platform Operator (§19.5) | R3.1, **G1 approval** | OA; Infra | §19.5.1 tables | `/platform` | operator-only | `platform_operator_events` | §19.5.8 | separate host; revoke all | security review, Brakeman |
| R3b | Historical Violations and corrections | R3.4 | AP; OA | §8 tables | review and correction services | the two new correction permissions | full | §14, §15 | additive | SoD specs (G3) |
| R4 | `working_weekdays`, `ScheduleChanger`, overlap validation, missing-schedule report | owner approval of this plan (R1 may land with it) | WF | assignment column | WF services, report | `assign_shifts` | changes | §14 | starts the D9 count | report shipped with it |
| R5 | assignment enforcement in every path | R3.2, R4 | WF | none | model validation | — | refusals | §14 | after deadlines | every path covered |
| R6 | Holiday Calendar | owner approval of this plan (R1 may land with it) | WF | holidays | CRUD | `manage_holidays` | CRUD | §14 | additive | calendar specs |
| R6b | leave management (§6.7), held settlement cases and D21 snapshot; termination-settlement writer **disabled** until R7 | R3.2, Q5 column | WF | leave tables, case, steps | WF services, accrual / carry-over / expiry job, UI | `approve_leave_requests`, `manage_leave_settings` | every entry and step | §14 R6b, §19.3 OT9 | additive; jobs idempotent | ledger property specs; D23 permission checks |
| R8 | expense validation | R2 | FS | none | validations | — | — | §14 | additive | specs |
| R9 | Cost Allocation Rules | R2 | FS + OA | rule tables | UI, services | `manage_cost_allocations` | versions | §14 | additive | rule specs |
| R10 | contract extension once (K, G8) + R7.0 infrastructure (§19.4.3–19.4.5) | R9, **R7.0 approval** | AP + FS | §19.4.3 tables, expense column and index | Approver, Reopener, HeldEntry* services, Finance supplementary expense | existing (A6) | §19.4.7 | §19.4.10, §19.4.11; no hold creator yet | parity with today before any hold | parity green; contract probe |
| R11 | reports: snapshot-first, Provisional, D2 | R10 | Reporting | none | read-only reports | existing | view audit as today | §14 R11, §19.4.6 | read-only | Provisional never summed into finalized |
| R7 | `ScheduledDays`, rates (§19.3), absence, leave effects, flagger, payout and settlement writer enabled | R4, R5, R6, R6b, R10, R11; D9 count | AP (reads WF) | breakdown keys | calculators, flagger, Parity Report | existing | calculation and holds | §14 R7, §19.3 | Parity Report reviewed before enabling per business | parity accepted by the owner per business |
| R12 | old checkbox removal, release 1 | R5 deployed and verified | WF | `ignored_columns` | UI | — | — | §14 | revert | verified in production |
| R13 | old column drop | R12 verified | WF | drop column | — | — | — | §14 | separate migration | schema clean |

### 19.11 Readiness assessment (revision 16)

| Category | Phases |
|---|---|
| **Ready for implementation** once the owner approves this plan and authorises the phase | R0, R2, R3.1, R3.2, R4, R6, R8 |
| **Ready after a prerequisite phase** | R3.3 (R0, R3.2), R3.4 (R3.1, R3.2), R3b (R3.4), R5 (R3.2, R4), R6b (R3.2, Q5 column), R9 (R2), R11 (R10), R12 (R5), R13 (R12) |
| **Ready after an owner approval of the plan or a design** | R1 (this plan), R3.5 (G1, §19.5), R10 (R7.0, §19.4), R7 (R7.0 through R10) |
| **Blocked by a genuine owner decision** | No phase. Release of held settlements: D20 (1) payout calculation. Resolution of a D25 pending case: Q55 (non-blocking; R7 builds the case as pending) |
| **Out of scope** | §17, plus: the payout calculation for not-required employees (D20 (1)); posting mechanics of historical corrections; branch holiday calendars (D3); biometric allocation drivers (J) |

### 19.12 Approval gates that remain for the owner

1. Approval of this plan as a whole (unblocks R1 and the phase authorisations). **Given 2026-11-10** (revision 17
   approved as the primary roadmap; revision 18). It is not an implementation authorisation (item 6).
2. Q55 (how a D25 pending settlement is eventually resolved; non-blocking).
3. The R7.0 design (§19.4) with approval items A1–A6.
4. The G1 design (§19.5) with approval items G-A1–G-A6.
5. The formal payout calculation for not-required employees (D20 (1)), whenever the owner chooses to define it.
6. Each phase's implementation authorisation, in the order of §19.10.

### 19.13 R3.1 implementation decisions (revision 17)

R3.1 was authorised on 2026-11-08 with the owner decisions D28–D32 (§2 V). The technical choices below are
**[T]**: they resolve inconsistencies between §6.6, §6.8, §8 and §18.2 G10 without changing an approved rule.

| ID | Choice | Reason |
|---|---|---|
| T-R31-1 | **Attempt-log boundary:** each delivery attempt's row is written in its own transaction after the delivery transaction has committed or rolled back (G10), not inside the locked transaction (§6.8 diagram) | A delivery transaction that fails as a whole (lost connection) still leaves its attempt recorded; exactly-once delivery depends only on the locked transaction. The counters on the event reflect committed attempts; the attempt log is the complete history. *Amended by T-R31-12 (hardening): when the delivery transaction fails as a whole, counters and the attempt row are written together in one independent transaction* |
| T-R31-2 | **`monitor_audit_failures` is built in R3.1** (§19.10, G2), in the administration permission group: business-level, not scopable, no dependency, never in a role preset; owners have it implicitly | The business dashboard needs it; the §18 question table lists Q42 (c) under R3.5 only because the platform side is there |
| T-R31-3 | **Counters:** `attempts` counts every delivery attempt; `consecutive_failures` counts failures since the last success and is the escalation counter. Both are kept | They are equal while an event is unresolved and differ after delivery (`consecutive_failures` returns to 0); the plan names both and removing one would change §8 |
| T-R31-4 | **Manual attempts:** `kind` exists with a check constraint that allows only `automatic` in R3.1. R3.5 adds the operator reference (with its foreign key to the platform-operator table) and widens the constraint in its own migration | No placeholder operator model and no unenforced actor column before the platform identity exists (G1); business users can never create a manual attempt |
| T-R31-5 | **Dashboard location:** a standalone `AuditFailuresController` (`/audit_failures`) on `ApplicationController`, authorised by Pundit and listed in the sidebar's administration group | `Admin::BaseController#require_admin_access!` does not admit `monitor_audit_failures`; widening it would let the permission open the admin entry point |
| T-R31-6 | **Retry schedule:** the original failed write is not a delivery attempt. The first retry runs 1 minute after it, then 5 and 15 minutes after each failure, then hourly; escalation at the third consecutive failed retry, once | Matches "backoff 1 min, 5 min, 15 min, then hourly" and "escalation when `consecutive_failures` reaches 3" (G10) |
| T-R31-7 | **Exactly-once:** the row lock (`FOR UPDATE NOWAIT`), the Audit Log insert and the resolution are one transaction; the delivered entry keeps the original actor, business, action, auditable, changes and metadata exactly, and the link is `pending_audit_events.audit_log_id` (unique) | G10's guarantee needs no marker in the entry, so §6.6 step (4)'s "the record's id is carried into the entry" is not used and the payload stays unchanged. *Amended by T-R31-11 (hardening): the lock alone cannot cover a first write whose commit confirmation was lost; a receipt table enforces exactly-once in the database* |
| T-R31-8 | **Writer contract:** `Audit::DurableEntry.record` is called outside any open caller transaction (it refuses otherwise), calls the existing `log_audit!` once, writes the durable record in its own transaction only when that fails, and enqueues after that transaction; a lost enqueue is recovered by the sweeper | A durable record written inside a transaction that later rolls back would be lost (§3.6). *Amended by T-R31-11 and T-R31-12 (hardening): the first write and its receipt are one transaction; the attempt time and key are fixed first; the transaction check needs no connection* |
| T-R31-9 | **Operational data only:** dashboard and badge queries select operational columns explicitly, so the payload is never loaded for display; stored failure information is the error class and PostgreSQL schema identifiers or invalid attribute names, as in the global audit report | D30 |
| T-R31-10 | **Due check:** an automatic attempt on an event that is not yet due does nothing, so a duplicate job never shortens the backoff | The sweeper and the original enqueue may both deliver a job for the same event |

**Hardening (revision 17, 2026-11-08).** After an independent review (findings M1–M3, L1–L9), the owner authorised
the following, with D33 and the D28 clarification (§2 V). Schema dependencies: all in migration
`20261108100000_create_pending_audit_events` (not yet released, so amended in place);
`config/initializers/schema_dumper_database_guards.rb` keeps the guard functions and triggers in `db/schema.rb`.

| ID | Choice | Reason |
|---|---|---|
| T-R31-11 | **Idempotency receipt.** Every AuditLog written through the durable path is inserted in the same transaction as a `durable_audit_receipts` row (`entry_key` uuid, unique; `audit_log_id`, unique). `Audit::DurableEntry` fixes the `entry_key` before the first write and keeps it on the pending event. Delivery, under the event's row lock, adopts an existing receipt for that key (resolving to its AuditLog, writing nothing); otherwise it inserts AuditLog + receipt + resolution in one savepoint. A composite foreign key makes a resolved event point at the AuditLog receipted under its own key. `audit_logs` is unchanged | A first write whose COMMIT succeeded but whose confirmation was lost raises `ConnectionFailed`; without a database key, the retry would write a second AuditLog. With the unique key, a second insert for the same entry fails and its savepoint takes the AuditLog with it — no fuzzy matching, no marker in the AuditLog payload, no change for existing callers |
| T-R31-12 | **Failure boundaries.** (a) Writer: the attempt time and key are fixed first; the open-transaction check reads the thread's leased connection without checking one out, so it cannot fail; any error of the first write (not only `ActiveRecordError`) keeps the entry pending; only a failure to write the pending event triggers D28; an enqueue failure after the event committed returns ok/pending and is only logged; logging failures never reach the caller. (b) Delivery (D33): a whole-transaction failure is recorded after the rollback in an independent transaction that locks the event, records the failure (unless that attempt's failure or delivery had in fact committed) and appends the attempt row — together or not at all; its wait for the row lock is bounded (`lock_timeout` 5 s), because after a lost connection the old backend can hold the lock until PostgreSQL notices | Findings L1, L2, M1 |
| T-R31-13 | **Exact retries, recovery-only sweeper.** After a recorded failure the next retry job is enqueued at `next_attempt_at`. Every enqueued retry holds a dispatch claim (`dispatch_claimed_until` = retry time + 10 minutes). The sweeper claims due events whose claim has lapsed in one transaction (`FOR UPDATE SKIP LOCKED`, at most 500), enqueues one job each, and on an enqueue failure releases that claim and continues. A duplicate job still does nothing (T-R31-10) | Findings L3, L4: the schedule is met to the minute (queue latency can only delay it); a backlog no longer piles up duplicates; a lost job is re-enqueued at most ~15 minutes after its retry time; two concurrent sweeps never claim the same event |
| T-R31-14 | **Database guards.** Triggers: receipts and attempt rows are append-only (no UPDATE / DELETE); a pending event is never deleted, its identity, payload and attempt time never change, a resolved event never changes, `attempts` never decreases and `escalated_at` is set once. Composite foreign keys: an attempt row is in its event's business; a resolved event names its own receipt. `TRUNCATE` (test cleanup) is not blocked | Finding L5: `update_all`, `update_columns` and `delete_all` bypass the model protections |
| T-R31-15 | **Sanitized reporting.** Every R3.1 error report hands `Rails.error` a `SanitizedError` carrying only the original class name, with a context of ids, counters, keys and PostgreSQL schema identifiers; log lines carry the same. The full payload reaches the application log only in the D28 fallback. The global `report_audit_failure` is unchanged | Finding L7: a PostgreSQL message can quote row values ("Failing row contains …"); D28 clarification |

---

## Appendix — documentation updates required elsewhere

| Document | Update | When |
|---|---|---|
| `CLAUDE.md` → Business Rules | Add "Attendance requirements" (A1–A11 summary), "Daily-paid attendance invariant" (L1–L9, L13, L14 summary: AP-owned rule, WF contract and lock, reject-only, Not Reviewed rule, rejected attempts audited after rollback with alert and retry), "Requirement history" (L10–L12, L18, L19, L25: mandatory selection and start date at creation, all-employee backfill, evidence rules, HR exception list), "Leave" (L6, L15, L16, L21–L23, L26–L28, L31–L33), "Historical Violations" and corrections (L17, L24, L30, L35), durable rejected-attempt audit and its alerts (L20, L29, L34), "Cost allocation" (B–J summary), the owner decisions D1–D8 (§2 M), D9–D14 (§2 N), D15 (§2 O), D16 (§2 P), D17–D18 (§2 Q), D19–D20 (§2 R), D21 (§2 S), D22–D23 (§2 T) and D24–D27 (§2 U), and the gate list of §10; reference this plan | With R1, after owner approval of this plan — not before, since `CLAUDE.md` describes binding rules for implemented code |
| `docs/architecture/module-boundaries.md` §3.3 | Scheduling eligibility follows `employee_attendance_requirements` (replaces the `requires_shift_assignment` paragraph); §3.2 table: add `requires_attendance` (WF, cache) | With R5 (when the behaviour changes) |
| `docs/architecture/module-boundaries.md` §14.1 A | New `period_finalized` payload (per-employee costs), `allocation_blockers`, snapshot ownership; floating note updated (no unallocated part for new periods) | With R10 |
| `docs/architecture/module-boundaries.md` §12.1 | The approved (L1) WF-defined, AP-implemented invariant check contract, the WF requirement read API and the WF invariant lock helper used by AP | With R3 |
| `docs/architecture/module-boundaries.md` §10–§11 | Ownership of the new tables: `employee_attendance_requirements` (WF), Historical Violation records and post-lock leave review items (AP, R3b), leave, leave-policy, leave-type, leave-batch, leave-balance ledger and approval-routing tables (WF, R6b), the unpaid-leave denominator setting (AP, R7), historical correction requests (AP, R3b), Finance Approver designations and the same-person setting (OA, R3b); AP's read of approved leave and settlement entries (allowed AP → WF) | With R3, R3b, R6b and R7 respectively |
| `docs/architecture/module-boundaries.md` §16 (infrastructure) | The durable rejected-attempt audit record and its retry job (L20), next to `AuditLoggable`; the attempt log and both audit-failure dashboards (L29, L34); `notifications` stays Legacy / unused | With R3 |
| `docs/architecture/module-boundaries.md` §18 (interaction / tenancy rules) and OA ownership | The platform-operator (System Administrator) identity and its cross-business read path, whose business meaning D1 sets; the G1 design is a new architecture decision, not a classification (§18.2 G1) | Before R3.5 |
| `docs/architecture/module-boundaries.md` §10–§11, §16 | Map `pending_audit_events`, `pending_audit_event_attempts` and `durable_audit_receipts` (Infrastructure, Audit), `platform_operators` (OA), `payroll_entry_finalization_holds` (AP) and `expenses.source_payroll_entry_id` (FS); flag the dependency report as stale (G7) | In the same commit as each migration |
| `docs/architecture/module-boundaries.md` §10–§11, §16 (revision 14) | Map `payroll_entry_finalization_holds`, `payroll_entry_hold_reviews`, `payroll_entry_late_finalizations` (AP), `expenses.source_payroll_entry_id` (FS), the held settlement case and step tables (WF), the payout approval and payment records (AP), `platform_operators`, `platform_operator_recovery_codes`, `platform_operator_events` (OA); the `Leave::SettlementRelease` contract (WF-defined, AP caller) in §12.1 | In the same commit as each migration (R6b, R10, R3.5) |
| `app/services/approvals/self_approval.rb` header comment | Name the historical-correction approver as a third caller (G3) | With R3b (code change, listed here for traceability) |
| `docs/quality/deferred-bugs.md` | Whether `ShiftAssignment.current`'s server date (`Date.current`) is covered by BUG-043 or needs its own entry — for the register's owner (G9) | At the next pilot backlog review |
| `docs/quality/deferred-bugs.md` (revision 14) | Candidate entry for the `.to_f` money conversion in `Payroll::EntryCalculator#resolve_insurance_snapshot` (§19.8 R-14), for the register's owner | At the next backlog review |
| `docs/architecture/floating-employees-implementation-plan.md` | Supersession note listing X1–X8 (added with revision 1, not yet committed). No change needed for revision 2: L1–L9 contradict nothing further in that plan beyond X2, whose effect row (§4.3) now also names its remaining "exempt daily" mentions, and the note's "that plan wins" clause already covers them | Done |
