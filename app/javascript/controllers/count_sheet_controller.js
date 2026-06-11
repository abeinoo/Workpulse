import { Controller } from "@hotwired/stimulus"

// Drives the stock-count counting screen:
//  • live difference per row (0 → green, + → yellow, − → red; blank → neutral)
//  • counting progress (counted / remaining / total / %)
//  • row filters (all / counted / not counted / differences only)
//  • quick-scan loop: pressing Enter in a counted-quantity field returns focus to
//    the barcode field, so scan → type → Enter → scan never needs the mouse.
export default class extends Controller {
  static targets = ["progressBar", "counted", "remaining", "total", "percent", "filterButton"]

  connect() {
    this.filterMode = "all"
    this.element.querySelectorAll("[data-quantity-field]").forEach((input) => this.#applyDifference(input))
    this.#refreshProgress()
  }

  recalc(event) {
    const input = event.target
    this.#applyDifference(input)
    this.#applyFilter(input.closest("[data-line-row]"))
    this.#refreshProgress()
  }

  // Enter in a counted-quantity field → back to the barcode field for the next scan.
  focusScanner(event) {
    event.preventDefault()
    const scanner = this.element.querySelector('[data-barcode-scanner-target="input"]')
    scanner?.focus()
    scanner?.select?.()
  }

  filter(event) {
    this.filterMode = event.currentTarget.dataset.filter || "all"
    this.filterButtonTargets.forEach((btn) =>
      btn.classList.toggle("is-active", btn.dataset.filter === this.filterMode))
    this.#rows().forEach((row) => this.#applyFilter(row))
  }

  // ── internals ──────────────────────────────────────────────────────────
  #rows() {
    return Array.from(this.element.querySelectorAll("[data-line-row]"))
  }

  #state(row) {
    const input = row.querySelector("[data-quantity-field]")
    const counted = !!input && input.value.trim() !== ""
    const system = parseFloat(row.dataset.systemQuantity) || 0
    const diff = counted ? (parseFloat(input.value) || 0) - system : null
    return { counted, diff }
  }

  #applyDifference(input) {
    const row = input.closest("[data-line-row]")
    const badge = row?.querySelector("[data-difference]")
    if (!badge) return
    const { counted, diff } = this.#state(row)

    badge.classList.remove("badge-success", "badge-warning", "badge-danger", "badge-neutral")
    if (!counted) {
      badge.textContent = "—"
      badge.classList.add("badge-neutral")
      return
    }
    badge.textContent = (diff > 0 ? "+" : "") + this.#format(diff)
    badge.classList.add(diff === 0 ? "badge-success" : diff > 0 ? "badge-warning" : "badge-danger")
  }

  #applyFilter(row) {
    if (!row) return
    const { counted, diff } = this.#state(row)
    const visible =
      this.filterMode === "counted"      ? counted :
      this.filterMode === "not_counted"  ? !counted :
      this.filterMode === "differences"  ? (counted && diff !== 0) :
      true
    row.hidden = !visible
  }

  #refreshProgress() {
    const rows = this.#rows()
    const total = rows.length
    const counted = rows.filter((row) => this.#state(row).counted).length
    const pct = total === 0 ? 0 : Math.round((counted * 100) / total)

    if (this.hasCountedTarget)   this.countedTarget.textContent = counted
    if (this.hasRemainingTarget) this.remainingTarget.textContent = total - counted
    if (this.hasTotalTarget)     this.totalTarget.textContent = total
    if (this.hasPercentTarget)   this.percentTarget.textContent = `${pct}%`
    if (this.hasProgressBarTarget) this.progressBarTarget.style.width = `${pct}%`
  }

  #format(n) {
    return Number.isInteger(n) ? String(n) : n.toFixed(3).replace(/\.?0+$/, "")
  }
}
