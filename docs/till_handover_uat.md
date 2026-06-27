# Till Handover — User Acceptance Testing (UAT)

**Feature:** Till Handover & Daily Reconciliation  
**Version:** Phase 4 (production candidate)  
**Goal:** Validate every business workflow path before production deployment

---

## Test Setup

**Required users:**

| User | Role/Permissions | Branch |
|---|---|---|
| Receptionist A | `create_shift_closing` | Branch 1 |
| Receptionist B | `create_shift_closing` | Branch 1 |
| Receptionist C | `create_shift_closing` | Branch 1 |
| Manager | `view_daily_reconciliation`, `verify_daily_reconciliation` | Branch 1 |
| Finance Admin | `view_daily_reconciliation`, `verify_daily_reconciliation` | All branches |
| Unassigned Staff | No till permissions | No branch |
| Owner | Full access | All branches |

**Required data:**
- Branch 1 with at least 3 receptionists assigned
- Payment methods: Cash (cash), Visa (card), Instapay (ewallet) — at minimum
- At least one cash-like method with `supports_refunds: true`

**Notation:** Each scenario is independent unless marked "Follows UAT-XX". Reset till state between unrelated scenarios by testing on different business dates.

---

## Part 1 — Business Day Lifecycle

These scenarios cover the complete day from open to verified. Run them in order on the same business date.

---

### UAT-01 — First receptionist of the day

**Preconditions:**
- No till handovers exist for today in Branch 1
- Receptionist A is logged in and assigned to Branch 1

**Steps:**
1. Navigate to My Till (sidebar)
2. Observe the hero card
3. Observe the available action buttons

**Expected result:**
- Hero card reads "No Handovers Recorded Yet"
- Sub-text: "When you are ready, hand the till over or start depositing"
- Two buttons present: "Hand Over to a Colleague" and "I Am Today's Depositor"
- History section is empty or absent
- No indication of any other user holding the till

---

### UAT-02 — First transfer of the day (Receptionist A → B)

**Preconditions:**
- Follows UAT-01
- Receptionist B is assigned to Branch 1

**Steps:**
1. As Receptionist A, tap "Hand Over to a Colleague"
2. Observe the form
3. Select Receptionist B as recipient
4. Enter amounts: Cash 1,500.00, Visa 320.00, Instapay 75.00
5. Leave notes blank
6. Tap "Hand Over the Till"

**Expected result:**
- Form shows recipient list containing only Receptionist B and C (not self, not users without `create_shift_closing`)
- On submit: redirected to My Till
- Hero card: "Waiting for %{B} to confirm"
- Sub-text: "Waiting for them to confirm receipt."
- No action buttons shown for Receptionist A
- History section shows one entry: A → B, status "Pending"

---

### UAT-03 — Pending transfer visible to recipient (Receptionist B)

**Preconditions:**
- Follows UAT-02
- Receptionist B logs in

**Steps:**
1. Navigate to My Till

**Expected result:**
- Missing-punch-style alert: "The Till Is Waiting for You"
- Body: "[Receptionist A] passed the till to you."
- Single primary button: "Accept the Till" — no other action buttons
- Confirmation dialog appears when "Accept the Till" is tapped: "You are about to take custody of the till. Continue?"

---

### UAT-04 — Receptionist B accepts the transfer

**Preconditions:**
- Follows UAT-03

**Steps:**
1. As Receptionist B, tap "Accept the Till"
2. Confirm the dialog

**Expected result:**
- Redirected to My Till
- Hero card: "You Hold the Till" — active variant
- Two buttons: "Hand Over to a Colleague" and "I Am Today's Depositor"
- History shows: A → B (Confirmed), time of acceptance visible
- As Receptionist A (reload): state changes to `:no_activity` or `:held_by_other` — no more pending outgoing entry

---

### UAT-05 — Second transfer of the day (Receptionist B → C)

**Preconditions:**
- Follows UAT-04

**Steps:**
1. As Receptionist B, tap "Hand Over to a Colleague"
2. Select Receptionist C
3. Enter different amounts: Cash 1,200.00, Visa 480.00, Instapay 0.00
4. Add a note: "Shift change at 14:00"
5. Submit

**Expected result:**
- My Till shows Receptionist B as waiting for C
- History now shows two entries in chronological order: A→B (Confirmed), B→C (Pending)
- The form submitted successfully with a 0.00 Instapay entry (zero values are allowed)

---

### UAT-06 — Receptionist C accepts, becomes depositor

**Preconditions:**
- Follows UAT-05

**Steps:**
1. As Receptionist C, accept the till from B
2. Tap "I Am Today's Depositor"
3. Confirm the dialog: "You are about to declare yourself today's depositor…"

**Expected result:**
- Confirmation dialog shown before navigating to form
- Form title: "Become Today's Depositor" with Receptionist C's name in a read-only card
- Amounts section shown — enter amounts: Cash 1,100.00, Visa 480.00
- Tap "Confirm Depositor Role"
- Redirected to My Till
- Hero card: "You Are Today's Depositor" (done/success variant)
- Sub-text: "Since [time]"
- Primary button: "Record a Deposit" — no handover buttons present
- History shows three entries, the last one labelled "Receptionist C — Depositor" with status "Confirmed"

---

### UAT-07 — First ATM deposit

**Preconditions:**
- Follows UAT-06
- Receptionist C is the depositor

**Steps:**
1. Tap "Record a Deposit"
2. Observe the form
3. Select "Cash" as method
4. Enter amount: 500.00
5. Set time of deposit to now
6. Enter reference: "ATM-001"
7. Submit

**Expected result:**
- Form only shows cash-like payment methods (Cash, Instapay — not Visa card)
- On submit: redirected to My Till
- Deposits section appears showing one deposit: Cash 500.00 at the entered time, reference "ATM-001"
- Total deposited: 500.00

---

### UAT-08 — Multiple ATM deposits by the same depositor

**Preconditions:**
- Follows UAT-07

**Steps:**
1. Tap "Record a Deposit" again
2. Select "Instapay"
3. Enter 75.00, reference "INST-001"
4. Submit
5. Return to My Till; tap "Record a Deposit" once more
6. Select "Cash", enter 1,000.00, reference "ATM-002"
7. Submit

**Expected result:**
- Each deposit adds a new line to the deposits section
- Total deposited updates: 500.00 + 75.00 + 1,000.00 = 1,575.00
- Each deposit shows its method, amount, time, and reference
- "Record a Deposit" button remains visible after each submission

---

### UAT-09 — Management audit view during active day

**Preconditions:**
- Follows UAT-08
- Manager is logged in

**Steps:**
1. Navigate to Finance → Daily Reconciliation
2. Observe the index
3. Click "View" for today's Branch 1 row

**Expected result:**
**Index row:**
- Date: today with "Today" badge
- Till Status: "Receptionist C" or "Deposited ✓" (depositor done state)
- Depositor column: "Yes" badge
- Verification: "Pending" badge

**Day view — six audit cards:**
1. "Who currently holds the till?" → Receptionist C, "Today's depositor"
2. "Who became today's depositor?" → Receptionist C, since [time]
3. "Were all transfers accepted?" → "All accepted"
4. "How much has been deposited?" → 1,575.00, "3 deposits"
5. "Remaining cash balance?" → shows positive remaining (cash collected minus deposited), amber colour
6. "Has this day been verified?" → "Not yet"

**Timeline:** Three nodes — A→B (Confirmed), B→C (Confirmed), C (Depositor) — with connecting lines, amounts visible per link

**Deposits section:** 3 rows matching the recorded deposits

**Verify form visible** at the bottom

---

### UAT-10 — Final deposit clears remaining balance

**Preconditions:**
- Follows UAT-09
- Receptionist C records the final deposit to bring remaining balance to zero

**Steps:**
1. As Receptionist C, record the remaining cash amount
2. Reload My Till; observe totals

**Expected result:**
- Remaining cash balance on day view: 0.00 (green colour)
- My Till shows total deposited matching total cash collected

---

### UAT-11 — Manager verifies the day

**Preconditions:**
- Follows UAT-10

**Steps:**
1. As Manager, navigate to Finance → Daily Reconciliation → day view
2. Scroll to "Verify This Day" section
3. Enter verification notes: "All deposits confirmed. Till balanced."
4. Tap "Confirm Verification"

**Expected result:**
- Redirected back to day view
- "Has this day been verified?" card: green, shows Manager's name
- Verification card at the bottom shows verified by Manager at [time]
- Verify form is no longer shown
- Index row for today: Verification column shows "Verified" badge (green)
- No DailyReconciliation record should have been created before this action

---

### UAT-12 — New business day resets state

**Preconditions:**
- Follows UAT-11
- Business day advances (change system clock or use a new date in test)

**Steps:**
1. As Receptionist A, navigate to My Till on the new day

**Expected result:**
- Hero card: "No Handovers Recorded Yet" (yesterday's chain is not visible)
- No deposits section
- History section empty or absent
- Yesterday's chain is still visible in Finance → Daily Reconciliation for the previous date

---

## Part 2 — Individual Workflow Scenarios

These scenarios test discrete behaviours in isolation.

---

### UAT-20 — Unauthorized acceptance attempt

**Preconditions:**
- A pending transfer exists from A to B
- Receptionist C (not the named recipient) is logged in

**Steps:**
1. As Receptionist C, navigate to My Till
2. Observe state

**Expected result:**
- My Till shows `:held_by_other` state: "Till is with [Receptionist B]" (B has not accepted yet — actually it's still with A until accepted; check the display reflects the correct current holder)
- No "Accept" button shown to Receptionist C
- Receptionist C cannot reach the accept URL directly (`/till_handovers/:id/accept`) — attempting PATCH returns unauthorized or redirects with an error

---

### UAT-21 — Depositor with zero cash collected

**Preconditions:**
- No till activity for today, Branch 1
- Only Visa card activity (no cash collected)

**Steps:**
1. As Receptionist A, tap "I Am Today's Depositor"
2. Enter Visa: 1,200.00, Cash: 0.00
3. Submit
4. Attempt to navigate to "Record a Deposit"

**Expected result:**
- Depositor form submits successfully with 0.00 cash
- On My Till: "Record a Deposit" button is shown (depositor state is correct)
- Deposit form only shows cash-like methods
- Since no cash was collected, the day view remaining balance is 0.00

---

### UAT-22 — Void a deposit

**Preconditions:**
- Receptionist C is the depositor with at least one recorded deposit (500.00)

**Steps:**
1. From the My Till deposits list, locate the 500.00 deposit
2. *(If there's a void action)* Void it with reason "Entered wrong amount"
3. Reload My Till

**Expected result:**
- Voided deposit no longer appears in active deposits list
- Total deposited is reduced by 500.00
- Day view in management reflects the reduced total
- The deposit record still exists in the DB (voided, not deleted)

---

### UAT-23 — Handover with payment method refunds

**Preconditions:**
- A payment method with `supports_refunds: true` (e.g. Cash) exists

**Steps:**
1. As current holder, tap "Hand Over to a Colleague"
2. Enter Cash collected: 2,000.00, Cash refunds: 150.00
3. Submit

**Expected result:**
- Both fields shown for refund-enabled methods; hidden field sends 0 for non-refund methods
- On the Till Transfer detail view: shows 2,000.00 collected, 150.00 refund, implying net 1,850.00
- Day view "collected amounts" shows 1,850.00 net for Cash

---

### UAT-24 — Multiple payment methods, zero on some

**Preconditions:**
- Business has Cash, Visa, Instapay, Gift Card payment methods active

**Steps:**
1. Create a handover with: Cash 800.00, Visa 320.00, Instapay 0.00, Gift Card 0.00
2. Submit and view the handover detail

**Expected result:**
- Form accepts all zero values without validation errors
- Till Transfer detail shows all four methods (or only non-zero ones — confirm which behaviour is expected)
- Day view collected amounts table includes all methods that had non-zero net amounts

---

### UAT-25 — Handover form validation — missing recipient

**Preconditions:**
- Current holder navigates to "Hand Over to a Colleague"

**Steps:**
1. Do not select a recipient
2. Submit the form

**Expected result:**
- Form does not submit
- Validation error: recipient is required for transfer-type handovers
- Amounts already entered are preserved on the re-rendered form

---

### UAT-26 — Negative amounts rejected

**Preconditions:**
- Any receptionist is current holder

**Steps:**
1. Open handover form
2. Enter Cash: -100.00
3. Submit

**Expected result:**
- Form does not submit
- Validation error: amounts must be ≥ 0
- OR: browser-level `min="0"` prevents negative input

---

### UAT-27 — View till transfer detail

**Preconditions:**
- At least one accepted transfer exists in today's chain

**Steps:**
1. Navigate to My Till
2. In the "Today's Activity" history, tap a transfer row

**Expected result:**
- Navigates to the Till Transfer detail page
- Shows: from user, to user (for transfers), type, accepted/pending status with time
- Shows collected amounts per method with any refunds shown separately
- Notes field shown if notes were entered
- "← My Till" back link present

---

### UAT-28 — Verify permissions — viewer cannot verify

**Preconditions:**
- A user with only `view_daily_reconciliation` (not `verify_daily_reconciliation`) is logged in

**Steps:**
1. Navigate to Finance → Daily Reconciliation → day view for today

**Expected result:**
- Day view loads correctly — all 6 audit cards visible
- Timeline visible
- Deposits visible
- "Verify This Day" form is NOT shown
- No verify button present anywhere on the page

---

### UAT-29 — Re-verification after first verification

**Preconditions:**
- A day has already been verified by Manager

**Steps:**
1. As Manager (or Finance Admin with `verify_daily_reconciliation`), navigate to that day's view

**Expected result:**
- "Verify This Day" form is absent
- Footer shows "Verified by [Manager] at [time]"
- Notes from first verification are shown

---

## Part 3 — Edge Cases

---

### UAT-40 — User without branch assignment

**Preconditions:**
- A user has `create_shift_closing` permission but no active `ShiftAssignment` for today

**Steps:**
1. User navigates to My Till

**Expected result:**
- Hero card: "No Branch Assigned"
- Message: "You are not assigned to a branch today. Contact your manager."
- No action buttons shown
- No history section

---

### UAT-41 — User without `create_shift_closing` permission

**Preconditions:**
- A user has no till-related permissions (e.g. a regular employee)

**Steps:**
1. User attempts to navigate to `/my_shift` directly

**Expected result:**
- Redirected to root path with a "not authorized" flash message
- "My Till" link does not appear in their sidebar

---

### UAT-42 — Race condition: two users attempt to start the first chain link simultaneously

**Preconditions:**
- No till activity today for Branch 1
- Both Receptionist A and Receptionist B attempt to submit a handover at the same moment

**Steps:**
1. Both users open the handover form simultaneously
2. Both submit within the same second

**Expected result:**
- One submission succeeds, creating the chain head
- The other receives a user-friendly error: "Someone else just opened today's till at the same time. Please refresh and try again."
- The system is in a consistent state — exactly one chain head exists
- The user who received the error can reload My Till and proceed normally

---

### UAT-43 — Race condition: two users attempt to accept the same transfer

**Preconditions:**
- A pending transfer from A to B exists
- (This tests the DB-level uniqueness of `previous_handover_id`)

**Steps:**
1. Receptionist B opens My Till on two browser sessions simultaneously
2. Both sessions see the "Accept the Till" button
3. Both tap accept simultaneously

**Expected result:**
- One acceptance succeeds
- The second attempt returns an error or is silently rejected
- The till state is consistent — the handover is accepted exactly once
- Reloading either session shows the correct post-acceptance state

---

### UAT-44 — Duplicate depositor attempt

**Preconditions:**
- Receptionist C has already created a depositor-type handover for today

**Steps:**
1. As Receptionist C (now the depositor), attempt to navigate to "I Am Today's Depositor" via URL manipulation

**Expected result:**
- Receptionist C is in `:depositor` state — the "I Am Today's Depositor" button is not shown on My Till
- If they manually navigate to `new_till_handover_path?type=depositor`, the `TillHandoverCreator` service rejects it: C is not the current holder (depositor closed the chain) — or the DB constraint fires

---

### UAT-45 — Creating a handover while a pending transfer exists

**Preconditions:**
- Receptionist A handed over to B (pending, not yet accepted by B)
- Receptionist A's state is `:waiting_outgoing`

**Steps:**
1. As Receptionist A, attempt to navigate to "Hand Over to a Colleague" via URL manipulation

**Expected result:**
- My Till shows `:waiting_outgoing` state — no action buttons for creating a new handover
- If URL is accessed directly, the service rejects it: A is no longer the current holder (chain tail is still A's outgoing, but it's pending, so A IS still the holder — verify actual behaviour)
- **Clarification:** A pending transfer means A's handover has no `accepted_at`, so the chain tail is still A's previous handover. Receptionist A IS still the holder. Creating another handover from A at this point would create a fork, blocked by the DB unique index on `previous_handover_id`.

---

### UAT-46 — Branch with no till activity (management view)

**Preconditions:**
- Branch 2 exists in the business with active receptionists but no till activity for the last 14 days

**Steps:**
1. Manager navigates to Finance → Daily Reconciliation

**Expected result:**
- Branch 2 does not appear in the index (no rows for it)
- No errors shown
- If the business has no till activity at all: "No till activity found in the last 14 days." empty state shown

---

### UAT-47 — Attempting deposit on a non-depositor handover

**Preconditions:**
- Receptionist B holds a transfer-type handover (not depositor type)

**Steps:**
1. Attempt to access `new_till_deposit_path?till_handover_id=[B's handover id]`

**Expected result:**
- Policy rejects the request — only a depositor-type handover where the actor is `from_user` may record deposits
- Redirected or shown "not authorized"

---

### UAT-48 — Deposit on non-cash payment method

**Preconditions:**
- Receptionist C is today's depositor
- Visa card method exists

**Steps:**
1. Attempt to submit a deposit with "Visa" selected via URL/form manipulation

**Expected result:**
- Visa does not appear in the deposit form (only cash-like methods shown)
- If submitted via manipulation: `TillDeposit` validation rejects it — "must be a cash-type method"

---

### UAT-49 — Zero-value deposit rejected

**Preconditions:**
- Receptionist C is today's depositor

**Steps:**
1. Navigate to "Record a Deposit"
2. Enter amount: 0.00
3. Submit

**Expected result:**
- Validation error: amount must be greater than 0
- Form re-rendered with error

---

### UAT-50 — Cross-day transition (previous day's chain not contaminating today)

**Preconditions:**
- Yesterday had a full chain (A→B→C depositor, verified)
- Today is a new business day

**Steps:**
1. As Receptionist A on the new day, navigate to My Till
2. As Manager, navigate to Finance → Daily Reconciliation

**Expected result:**
- My Till shows `:no_activity` for today — yesterday's chain is invisible to receptionists
- Management index shows yesterday's row (verified) and no row for today yet
- Yesterday's row links to the correct day detail showing yesterday's data
- Today's day detail (accessed via by-date URL) shows empty chain

---

### UAT-51 — Mobile responsiveness

**Preconditions:**
- Use Chrome DevTools in mobile emulation (iPhone SE, 375px) or a real device

**Steps:**
1. Navigate through the complete receptionist workflow: My Till → Hand Over form → Depositor form → Deposit form
2. Verify tap targets, text legibility, scroll behaviour

**Expected result:**
- All CTAs are easily tappable (minimum 44px touch target)
- Form fields display correctly without horizontal overflow
- The `emp-dashboard` single-column layout fills the viewport
- The hero card is readable and not truncated
- The history list rows are compact but legible
- No horizontal scrollbar on any till-related page

---

### UAT-52 — Arabic RTL layout

**Preconditions:**
- Switch system/user language to Arabic

**Steps:**
1. Navigate the complete receptionist workflow in Arabic
2. Verify RTL layout on My Till, handover form, deposit form, and management day view

**Expected result:**
- All text is displayed right-to-left
- "Today's Activity" history arrows display as "← (left arrow)" appropriate for RTL (`%{from} ← %{to}`)
- Form labels, inputs, and buttons align correctly
- The `emp-dashboard` column layout respects RTL padding/margin
- Timeline connecting lines still appear correctly
- No LTR text bleeding (amounts, timestamps, names)
- Arabic translations display correctly without placeholder text (`%{…}`) appearing verbatim

---

### UAT-53 — Dark mode

**Preconditions:**
- OS dark mode enabled (or use browser DevTools to emulate `prefers-color-scheme: dark`)

**Steps:**
1. Navigate through My Till, handover form, deposit form, management day view

**Expected result:**
- Hero card background, text, and state colours (active/idle/done variants) are legible in dark mode
- Audit cards on the day view have correct contrast
- Timeline connecting lines and dots are visible
- Form fields, labels, and error messages are legible
- No white rectangles or invisible elements due to hardcoded `#fff` backgrounds

---

## Part 4 — Permission Boundary Matrix

Verify each route returns the expected HTTP response for each user type.

| Route | Receptionist (with `create_shift_closing`) | Staff (no permission) | Manager (`view_daily_reconciliation`) | Owner |
|---|---|---|---|---|
| `GET /my_shift` | 200 | 302 (root) | 302 (root) | 200 |
| `GET /till_handovers/new` | 200 | 302 | 302 | 200 |
| `POST /till_handovers` | 200/302 | 302 | 302 | 200/302 |
| `PATCH /till_handovers/:id/accept` | 200 (if recipient) / 302 (if not) | 302 | 302 | 200 |
| `GET /till_deposits/new` | 200 (if depositor) / 302 (if not) | 302 | 302 | 200 |
| `POST /till_deposits` | 200/302 | 302 | 302 | 200/302 |
| `GET /finance/daily_reconciliations` | 302 (finance gate) | 302 | 200 | 200 |
| `GET /finance/daily_reconciliations/day` | 302 | 302 | 200 | 200 |
| `PATCH /finance/daily_reconciliations/verify_day` | 302 | 302 | 302 (view only) | 200 |
| `PATCH /finance/daily_reconciliations/verify_day` | — | — | 200 (with `verify_daily_reconciliation`) | 200 |

---

## Pass / Fail Criteria

The feature is **production-ready** when:

- All scenarios in Parts 1–3 pass without unexpected behaviour
- All permission boundaries in Part 4 return the expected responses
- No JavaScript console errors appear during the workflows
- No untranslated placeholder keys (e.g. `translation missing:`) appear in either language
- The developer signs off on the audit log — every create/accept/verify action should produce an entry in the audit log with the correct actor, action, and metadata

---

## Known Limitations (out of scope for this release)

- There is no "undo accepted transfer" path. Once accepted, the recipient must create a new handover to pass custody.
- There is no notification mechanism (push, email, SMS) to alert the named recipient of a pending transfer.
- The management index covers 14 days. Older days require direct URL access via `day?branch_id=X&date=Y`.
- Deposits can only be created, voided, or viewed — there is no edit path.
