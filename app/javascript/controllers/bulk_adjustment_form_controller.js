import { Controller } from "@hotwired/stimulus"

/**
 * bulk-adjustment-form
 *
 * Manages the spreadsheet-style bulk adjustment entry:
 *  - Dynamic row add / remove
 *  - Live totals (bonus total, deduction total, row count)
 *  - Mass-set: apply a value to the same field across all rows
 *  - Keyboard navigation: Tab across cells, Enter / ArrowDown to next row
 *  - Clipboard paste: parses tab-separated or comma-separated text into rows
 *  - Review section: shows a grouped summary before the form submits
 */
export default class extends Controller {
  static targets = [
    "body",          // <tbody> that holds rows
    "template",      // <template> containing one blank row
    "emptyState",    // shown when body has no rows
    "totalBonus",    // live display of total bonus amount
    "totalDeduction",// live display of total deduction amount
    "totalRows",     // live count of filled-in rows
    "reviewSection", // the review panel shown before submit
    "reviewBody",    // table body inside review panel
    "submitBtn",     // the main submit button
  ]

  static values = {
    positiveTypes: { type: Array, default: ["cash_incentive", "commission"] },
    currency:      { type: String, default: "SAR" }
  }

  connect() {
    this.updateTotals()
    this.#syncEmptyState()
  }

  // ── Row management ────────────────────────────────────────────────────────

  addRow(event) {
    event?.preventDefault()
    const index = Date.now()
    const html  = this.templateTarget.innerHTML.replaceAll("NEW_INDEX", index)
    this.bodyTarget.insertAdjacentHTML("beforeend", html)
    this.#syncEmptyState()
    this.updateTotals()

    // Focus the first input in the new row
    const newRow = this.bodyTarget.lastElementChild
    newRow?.querySelector("select,input")?.focus()
  }

  removeRow(event) {
    event.preventDefault()
    const row = event.currentTarget.closest("[data-bulk-row]")
    row?.remove()
    this.#syncEmptyState()
    this.updateTotals()
  }

  duplicateRow(event) {
    event.preventDefault()
    const srcRow = event.currentTarget.closest("[data-bulk-row]")
    if (!srcRow) return

    const index  = Date.now()
    const clone  = srcRow.cloneNode(true)

    // Re-key all name/id attributes to the new index
    clone.querySelectorAll("[name],[id]").forEach(el => {
      if (el.name) el.name = el.name.replace(/\[\d+\]/, `[${index}]`)
      if (el.id)   el.id   = el.id.replace(/_\d+_/, `_${index}_`)
    })

    srcRow.insertAdjacentElement("afterend", clone)
    this.#syncEmptyState()
    this.updateTotals()
  }

  // ── Mass-set actions ──────────────────────────────────────────────────────

  massSetType(event) {
    const type = event.currentTarget.value
    if (!type) return
    this.#rowInputs("[data-field='adjustment_type']").forEach(el => { el.value = type })
    event.currentTarget.value = ""
    this.updateTotals()
  }

  massSetReason(event) {
    event.preventDefault()
    const reason = prompt(this.element.dataset.massReasonPrompt || "Reason for all rows:")
    if (reason == null) return
    this.#rowInputs("[data-field='reason']").forEach(el => { el.value = reason })
  }

  massSetAmount(event) {
    event.preventDefault()
    const amt = prompt(this.element.dataset.massAmountPrompt || "Amount for all rows:")
    if (amt == null || isNaN(parseFloat(amt))) return
    this.#rowInputs("[data-field='amount']").forEach(el => { el.value = parseFloat(amt).toFixed(2) })
    this.updateTotals()
  }

  // ── Live totals ───────────────────────────────────────────────────────────

  updateTotals() {
    let bonus      = 0
    let deduction  = 0
    let filledRows = 0

    this.bodyTarget.querySelectorAll("[data-bulk-row]").forEach(row => {
      const typeEl   = row.querySelector("[data-field='adjustment_type']")
      const amountEl = row.querySelector("[data-field='amount']")
      if (!typeEl || !amountEl) return

      const amount = parseFloat(amountEl.value) || 0
      if (amount <= 0 || !typeEl.value) return

      filledRows++
      if (this.positiveTypesValue.includes(typeEl.value)) {
        bonus += amount
      } else {
        deduction += amount
      }
    })

    if (this.hasTotalBonusTarget)      this.totalBonusTarget.textContent      = this.#fmt(bonus)
    if (this.hasTotalDeductionTarget)  this.totalDeductionTarget.textContent  = this.#fmt(deduction)
    if (this.hasTotalRowsTarget)       this.totalRowsTarget.textContent        = filledRows
  }

  // ── Review section ────────────────────────────────────────────────────────

  showReview(event) {
    event.preventDefault()
    const rows = this.#collectRows()

    if (rows.length === 0) {
      // Nothing to review — submit directly
      this.element.closest("form")?.submit()
      return
    }

    this.#renderReview(rows)
    if (this.hasReviewSectionTarget) {
      this.reviewSectionTarget.hidden = false
      this.reviewSectionTarget.scrollIntoView({ behavior: "smooth", block: "start" })
    }
  }

  hideReview(event) {
    event?.preventDefault()
    if (this.hasReviewSectionTarget) this.reviewSectionTarget.hidden = true
  }

  confirmSubmit(event) {
    event.preventDefault()
    this.element.closest("form")?.submit()
  }

  // ── Keyboard navigation ───────────────────────────────────────────────────

  handleKeydown(event) {
    const el  = event.target
    const row = el.closest("[data-bulk-row]")
    if (!row) return

    if (event.key === "Enter") {
      event.preventDefault()
      // Move to next row's same-column field, or add a new row
      const cells    = Array.from(row.querySelectorAll("input,select"))
      const idx      = cells.indexOf(el)
      const nextRow  = row.nextElementSibling

      if (nextRow) {
        const nextCells = nextRow.querySelectorAll("input,select")
        nextCells[idx]?.focus()
      } else {
        this.addRow()
      }
    }

    if (event.key === "ArrowDown" && !event.shiftKey) {
      const nextRow = row.nextElementSibling
      if (nextRow) {
        const cells     = Array.from(row.querySelectorAll("input,select"))
        const nextCells = Array.from(nextRow.querySelectorAll("input,select"))
        const idx       = cells.indexOf(el)
        nextCells[idx]?.focus()
        event.preventDefault()
      }
    }

    if (event.key === "ArrowUp" && !event.shiftKey) {
      const prevRow = row.previousElementSibling
      if (prevRow) {
        const cells     = Array.from(row.querySelectorAll("input,select"))
        const prevCells = Array.from(prevRow.querySelectorAll("input,select"))
        const idx       = cells.indexOf(el)
        prevCells[idx]?.focus()
        event.preventDefault()
      }
    }
  }

  // ── Clipboard paste ───────────────────────────────────────────────────────

  handlePaste(event) {
    // Only intercept paste on the tbody itself, not inside a single input
    if (event.target.tagName === "INPUT" || event.target.tagName === "SELECT") return

    const text = event.clipboardData?.getData("text/plain")
    if (!text) return

    event.preventDefault()
    const lines    = text.split("\n").map(l => l.trim()).filter(Boolean)
    const colCount = lines[0]?.includes("\t") ? "tab" : "comma"

    lines.forEach(line => {
      const parts = colCount === "tab" ? line.split("\t") : line.split(",")
      const [empCode, amount, reason, adjType] = parts.map(p => p?.trim())
      if (!empCode) return

      const index = Date.now() + Math.random()
      const html  = this.templateTarget.innerHTML.replaceAll("NEW_INDEX", index)
      this.bodyTarget.insertAdjacentHTML("beforeend", html)

      const newRow = this.bodyTarget.lastElementChild
      // Try to match employee by searching the select options
      const empSelect = newRow.querySelector("[data-field='employee_select']")
      if (empSelect) {
        const opt = Array.from(empSelect.options).find(o =>
          o.dataset.code?.toLowerCase() === empCode.toLowerCase() ||
          o.text.toLowerCase().includes(empCode.toLowerCase())
        )
        if (opt) empSelect.value = opt.value
      }

      const amountEl = newRow.querySelector("[data-field='amount']")
      if (amountEl && amount) amountEl.value = parseFloat(amount).toFixed(2)

      const reasonEl = newRow.querySelector("[data-field='reason']")
      if (reasonEl && reason) reasonEl.value = reason

      const typeEl = newRow.querySelector("[data-field='adjustment_type']")
      if (typeEl && adjType) {
        const match = Array.from(typeEl.options).find(o =>
          o.value.toLowerCase() === adjType.toLowerCase()
        )
        if (match) typeEl.value = match.value
      }
    })

    this.#syncEmptyState()
    this.updateTotals()
  }

  // ── Private helpers ───────────────────────────────────────────────────────

  #rowInputs(selector) {
    return Array.from(this.bodyTarget.querySelectorAll(`[data-bulk-row] ${selector}`))
  }

  #collectRows() {
    return Array.from(this.bodyTarget.querySelectorAll("[data-bulk-row]"))
      .map(row => {
        const userSelect = row.querySelector("[data-field='employee_select']")
        const typeSelect = row.querySelector("[data-field='adjustment_type']")
        const amountEl  = row.querySelector("[data-field='amount']")
        const reasonEl  = row.querySelector("[data-field='reason']")

        return {
          employee: userSelect?.options[userSelect.selectedIndex]?.text || "—",
          type:     typeSelect?.options[typeSelect.selectedIndex]?.text || "—",
          amount:   parseFloat(amountEl?.value) || 0,
          reason:   reasonEl?.value || "—",
          positive: this.positiveTypesValue.includes(typeSelect?.value)
        }
      })
      .filter(r => r.amount > 0)
  }

  #renderReview(rows) {
    if (!this.hasReviewBodyTarget) return

    const grouped = {}
    rows.forEach(r => {
      const key = r.type
      if (!grouped[key]) grouped[key] = { positive: r.positive, rows: [], total: 0 }
      grouped[key].rows.push(r)
      grouped[key].total += r.amount
    })

    this.reviewBodyTarget.innerHTML = Object.entries(grouped).map(([type, g]) =>
      `<tr>
        <td>${type}</td>
        <td>${g.rows.length}</td>
        <td class="${g.positive ? 'text-success' : 'text-danger'}">
          ${g.positive ? "+" : "−"}${this.#fmt(g.total)}
        </td>
      </tr>`
    ).join("")
  }

  #fmt(amount) {
    return new Intl.NumberFormat(undefined, {
      minimumFractionDigits: 2,
      maximumFractionDigits: 2
    }).format(amount)
  }

  #syncEmptyState() {
    if (!this.hasEmptyStateTarget) return
    const rows = this.bodyTarget.querySelectorAll("[data-bulk-row]")
    this.emptyStateTarget.hidden = rows.length > 0
  }
}
