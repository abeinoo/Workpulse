import { Controller } from "@hotwired/stimulus"

// Drives the Branch Distribution section of the expense form.
// Reacts to the allocation_mode select to show/hide the percentage/amount
// columns, display contextual hints, maintain a live running total, and gate
// the Save button until allocations sum to exactly 100 % (percentage mode) or
// exactly the expense amount (amount / "manual" mode). The server re-validates
// both (Expense#allocations_consistent_when_shared) — this is guidance only.
export default class extends Controller {
  static targets = [
    "section",
    "modeSelect",
    "pctHeader",
    "pctCell",
    "pctInput",
    "amtHeader",
    "amtCell",
    "amtInput",
    "branchSelect",
    "equalMsg",
    "pctMsg",
    "amountMsg",
    "expenseAmount",
    "amountSummary",
    "amountTotal",
    "amountDistributed",
    "amountRemaining",
    "summary",
    "duplicateMsg",
    "submitBtn"
  ]

  static values = {
    currency: String,
    rtl: Boolean,
    shortMessage: String,
    exceedsMessage: String,
    notPositiveMessage: String,
    precisionMessage: String
  }

  connect() {
    this.#apply()
  }

  // Called when the mode <select> changes.
  modeChanged() {
    this.#apply()
  }

  // Called by expense-scope#branchChanged when the branch/shared choice
  // flips, so the submit button reflects the newly (ir)relevant section.
  refresh() {
    this.#apply()
  }

  // Called on keyup/change of any percentage input.
  inputChanged() {
    this.#updateSummary()
  }

  // Called when a row's branch <select> changes. A branch may appear only
  // once per distribution (Expense validates the same server-side): picking a
  // branch another visible row already holds clears THIS select — the
  // existing row stays as it was — and shows the duplicate message. The
  // cleared select is `required`, so the duplicate row can't be submitted.
  branchChanged(event) {
    const select = event.target
    const taken  = this.#visibleBranchSelects.filter(s => s !== select).map(s => s.value)

    this.#duplicateRejected = select.value !== "" && taken.includes(select.value)
    if (this.#duplicateRejected) select.value = ""
    select.classList.toggle("is-error", this.#duplicateRejected)

    this.#updateSummary()
  }

  // Called after line-items#remove soft-removes (hides) a persisted row. A new
  // row is detached from the DOM instead, which skips this action — that path
  // is covered by branchSelectTargetDisconnected.
  rowsChanged() {
    this.#duplicateRejected = false
    this.#updateSummary()
  }

  // Stimulus target lifecycle — fires whenever a new row is inserted by
  // line_items_controller (including via the <template> clone).
  pctCellTargetConnected(cell) {
    cell.hidden = this.#isEqual || this.#isAmount
  }

  pctInputTargetConnected(input) {
    input.disabled = this.#isEqual || this.#isAmount || this.#sectionHidden
    this.#updateSummary()
  }

  pctInputTargetDisconnected() {
    this.#updateSummary()
  }

  amtCellTargetConnected(cell) {
    cell.hidden = !this.#isAmount
  }

  amtInputTargetConnected(input) {
    input.disabled = !this.#isAmount || this.#sectionHidden
    this.#updateSummary()
  }

  amtInputTargetDisconnected() {
    this.#updateSummary()
  }

  // Stimulus target lifecycle — fires for each row's branch <select>,
  // including on initial connect and on rows inserted via the template clone.
  branchSelectTargetConnected(select) {
    select.disabled = this.#sectionHidden
  }

  branchSelectTargetDisconnected() {
    this.rowsChanged()
  }

  // ── private ──────────────────────────────────────────────────────────────

  #duplicateRejected = false

  // A `required` field inside a `hidden` ancestor is still a candidate for
  // native constraint validation in some browsers — the ancestor's `hidden`
  // attribute alone does not exempt it. Whenever the whole distribution
  // section is irrelevant (a specific branch is selected), every required
  // control inside it must also be `disabled` so it can never silently block
  // submission of the rest of the form.
  #apply() {
    const eq  = this.#isEqual
    const amt = this.#isAmount
    const sectionHidden = this.#sectionHidden

    if (this.hasModeSelectTarget) this.modeSelectTarget.disabled = sectionHidden

    if (this.hasPctHeaderTarget) this.pctHeaderTarget.hidden = eq || amt
    if (this.hasAmtHeaderTarget) this.amtHeaderTarget.hidden = !amt

    this.pctCellTargets.forEach(c => { c.hidden = eq || amt })
    this.pctInputTargets.forEach(i => { i.disabled = eq || amt || sectionHidden })
    this.amtCellTargets.forEach(c => { c.hidden = !amt })
    this.amtInputTargets.forEach(i => { i.disabled = !amt || sectionHidden })
    this.branchSelectTargets.forEach(s => { s.disabled = sectionHidden })

    if (this.hasEqualMsgTarget)  this.equalMsgTarget.hidden  = !eq
    if (this.hasPctMsgTarget)    this.pctMsgTarget.hidden    =  eq || amt
    if (this.hasAmountMsgTarget) this.amountMsgTarget.hidden = !amt

    this.#updateSummary()
  }

  #updateSummary() {
    if (!this.hasSummaryTarget) return

    if (this.hasAmountSummaryTarget) {
      this.amountSummaryTarget.hidden = !this.#isAmount || this.#sectionHidden
    }

    // Section irrelevant (a specific branch is selected) — distribution is
    // ignored entirely, so it can never block the save button.
    if (this.#sectionHidden) {
      if (this.hasDuplicateMsgTarget) this.duplicateMsgTarget.hidden = true
      this.#setSubmitDisabled(false)
      return
    }

    // Duplicates already on the page (e.g. a server re-render) block saving
    // until one of the rows is changed or removed.
    const hasDuplicate = this.#hasDuplicateBranches
    if (this.hasDuplicateMsgTarget) {
      this.duplicateMsgTarget.hidden = !(hasDuplicate || this.#duplicateRejected)
    }
    if (hasDuplicate) {
      this.summaryTarget.textContent = ""
      this.#setSubmitDisabled(true)
      return
    }

    if (this.#methodBlank) {
      this.summaryTarget.textContent = "يرجى اختيار طريقة التوزيع."
      this.summaryTarget.className = "form-hint text-warning"
      this.#setSubmitDisabled(true)
      return
    }

    const count = this.#visibleRowCount

    if (this.#isEqual) {
      if (count === 0) {
        this.summaryTarget.textContent = "يرجى اختيار فرع واحد على الأقل."
        this.summaryTarget.className = "form-hint text-warning"
        this.#setSubmitDisabled(true)
      } else if (count === 1) {
        this.summaryTarget.textContent = "سيتم تخصيص 100٪ من المصروف لهذا الفرع."
        this.summaryTarget.className = "form-hint"
        this.#setSubmitDisabled(false)
      } else {
        const pct = (100 / count).toFixed(2)
        this.summaryTarget.textContent =
          `سيتم توزيع المصروف على ${count} فروع بنسبة ${pct}٪ لكل فرع.`
        this.summaryTarget.className = "form-hint"
        this.#setSubmitDisabled(false)
      }
      return
    }

    if (this.#isAmount) {
      this.#updateAmountSummary(count)
      return
    }

    // Percentage mode
    if (count === 0) {
      this.summaryTarget.textContent = "يرجى إضافة فرع واحد على الأقل."
      this.summaryTarget.className = "form-hint text-warning"
      this.#setSubmitDisabled(true)
      return
    }

    const visibleInputs = this.pctInputTargets.filter(
      i => !i.closest("[data-line-row]")?.hidden
    )
    const total   = visibleInputs.reduce((s, i) => s + parseFloat(i.value || 0), 0)
    const rounded = Math.round(total * 100) / 100

    this.summaryTarget.textContent = `إجمالي النسب الحالية: ${rounded}٪ من 100٪.`
    if (rounded === 100) {
      this.summaryTarget.className = "form-hint text-success"
      this.#setSubmitDisabled(false)
    } else if (rounded > 100) {
      this.summaryTarget.className = "form-hint text-danger"
      this.#setSubmitDisabled(true)
    } else {
      this.summaryTarget.className = "form-hint text-warning"
      this.#setSubmitDisabled(true)
    }
  }

  // Amount mode — all arithmetic in integer minor units (cents) parsed from
  // the input strings, so the equality check is exact (no float drift).
  #updateAmountSummary(count) {
    const total = this.#toCents(this.hasExpenseAmountTarget ? this.expenseAmountTarget.value : "")
    const visibleInputs = this.amtInputTargets.filter(
      i => !i.closest("[data-line-row]")?.hidden
    )
    const rows        = visibleInputs.map(i => this.#toCents(i.value))
    const distributed = rows.reduce((s, c) => s + (Number.isNaN(c) ? 0 : c), 0)
    const totalCents  = Number.isNaN(total) ? 0 : total
    const remaining   = totalCents - distributed

    if (this.hasAmountTotalTarget)       this.amountTotalTarget.textContent       = this.#money(totalCents)
    if (this.hasAmountDistributedTarget) this.amountDistributedTarget.textContent = this.#money(distributed)
    if (this.hasAmountRemainingTarget)   this.amountRemainingTarget.textContent   = this.#money(remaining)

    let message, tone
    if (count === 0) {
      message = "يرجى إضافة فرع واحد على الأقل."
      tone    = "text-warning"
    } else if (rows.some(c => Number.isNaN(c))) {
      message = this.precisionMessageValue
      tone    = "text-danger"
    } else if (rows.some(c => c <= 0)) {
      message = this.notPositiveMessageValue
      tone    = "text-warning"
    } else if (remaining > 0) {
      message = this.shortMessageValue.replace("%{amount}", this.#money(remaining))
      tone    = "text-warning"
    } else if (remaining < 0) {
      message = this.exceedsMessageValue.replace("%{amount}", this.#money(-remaining))
      tone    = "text-danger"
    } else {
      message = ""
      tone    = "text-success"
    }

    this.summaryTarget.textContent = message
    this.summaryTarget.className   = `form-hint ${tone}`
    this.#setSubmitDisabled(!(count > 0 && totalCents > 0 && remaining === 0 && tone === "text-success"))
  }

  // "12.5" → 1250. Blank → 0. Negative → -1 (flagged as not positive).
  // More than 2 decimals or non-numeric → NaN.
  #toCents(raw) {
    const s = String(raw ?? "").trim()
    if (s === "") return 0
    if (s.startsWith("-")) return -1
    const m = s.match(/^(\d*)(?:\.(\d{0,2}))?$/)
    if (!m) return NaN
    return Number(m[1] || 0) * 100 + Number((m[2] || "").padEnd(2, "0"))
  }

  // Mirrors ApplicationHelper#format_currency: "20.00 ج.م" (ar) / "EGP 20.00".
  #money(cents) {
    const sign  = cents < 0 ? "-" : ""
    const abs   = Math.abs(cents)
    const whole = Math.floor(abs / 100).toLocaleString("en-US")
    const num   = `${sign}${whole}.${String(abs % 100).padStart(2, "0")}`
    return this.rtlValue ? `${num} ${this.currencyValue}` : `${this.currencyValue} ${num}`
  }

  #setSubmitDisabled(disabled) {
    if (this.hasSubmitBtnTarget) this.submitBtnTarget.disabled = disabled
  }

  get #methodBlank() {
    return !this.hasModeSelectTarget || this.modeSelectTarget.value === ""
  }

  get #visibleBranchSelects() {
    return this.branchSelectTargets.filter(s => !s.closest("[data-line-row]")?.hidden)
  }

  get #hasDuplicateBranches() {
    const values = this.#visibleBranchSelects.map(s => s.value).filter(v => v !== "")
    return new Set(values).size !== values.length
  }

  get #isAmount() {
    return this.hasModeSelectTarget && this.modeSelectTarget.value === "manual"
  }

  get #isEqual() {
    return this.hasModeSelectTarget && this.modeSelectTarget.value === "equal"
  }

  get #sectionHidden() {
    return this.hasSectionTarget && this.sectionTarget.hidden
  }

  get #visibleRowCount() {
    return this.element.querySelectorAll("[data-line-row]:not([hidden])").length
  }
}
