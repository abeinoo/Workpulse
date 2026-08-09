import { Controller } from "@hotwired/stimulus"

// Drives the Branch Distribution section of the expense form.
// Reacts to the allocation_mode select to show/hide the percentage column,
// display contextual hints, maintain a live running total, and gate the
// Save button in percentage mode until allocations sum to exactly 100 %.
export default class extends Controller {
  static targets = [
    "section",
    "modeSelect",
    "pctHeader",
    "pctCell",
    "pctInput",
    "branchSelect",
    "equalMsg",
    "pctMsg",
    "summary",
    "submitBtn"
  ]

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

  // Stimulus target lifecycle — fires whenever a new row is inserted by
  // line_items_controller (including via the <template> clone).
  pctCellTargetConnected(cell) {
    cell.hidden = this.#isEqual
  }

  pctInputTargetConnected(input) {
    input.disabled = this.#isEqual || this.#sectionHidden
    this.#updateSummary()
  }

  pctInputTargetDisconnected() {
    this.#updateSummary()
  }

  // Stimulus target lifecycle — fires for each row's branch <select>,
  // including on initial connect and on rows inserted via the template clone.
  branchSelectTargetConnected(select) {
    select.disabled = this.#sectionHidden
  }

  // ── private ──────────────────────────────────────────────────────────────

  // A `required` field inside a `hidden` ancestor is still a candidate for
  // native constraint validation in some browsers — the ancestor's `hidden`
  // attribute alone does not exempt it. Whenever the whole distribution
  // section is irrelevant (a specific branch is selected), every required
  // control inside it must also be `disabled` so it can never silently block
  // submission of the rest of the form.
  #apply() {
    const eq = this.#isEqual
    const sectionHidden = this.#sectionHidden

    if (this.hasModeSelectTarget) this.modeSelectTarget.disabled = sectionHidden

    if (this.hasPctHeaderTarget) this.pctHeaderTarget.hidden = eq

    this.pctCellTargets.forEach(c => { c.hidden = eq })
    this.pctInputTargets.forEach(i => { i.disabled = eq || sectionHidden })
    this.branchSelectTargets.forEach(s => { s.disabled = sectionHidden })

    if (this.hasEqualMsgTarget) this.equalMsgTarget.hidden = !eq
    if (this.hasPctMsgTarget)   this.pctMsgTarget.hidden   =  eq

    this.#updateSummary()
  }

  #updateSummary() {
    if (!this.hasSummaryTarget) return

    // Section irrelevant (a specific branch is selected) — distribution is
    // ignored entirely, so it can never block the save button.
    if (this.#sectionHidden) {
      this.#setSubmitDisabled(false)
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

  #setSubmitDisabled(disabled) {
    if (this.hasSubmitBtnTarget) this.submitBtnTarget.disabled = disabled
  }

  get #methodBlank() {
    return !this.hasModeSelectTarget || this.modeSelectTarget.value === ""
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
