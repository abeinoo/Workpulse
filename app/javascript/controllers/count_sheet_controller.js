import { Controller } from "@hotwired/stimulus"

// Drives the stock-count counting screen:
//  • live difference per row (0 → green, + → yellow, − → red; blank → neutral)
//  • counting progress (counted / remaining / total / %)
//  • row filters (all / counted / not counted / differences only)
//  • quick-scan loop: pressing Enter in a counted-quantity field returns focus to
//    the barcode field, so scan → type → Enter → scan never needs the mouse.
//  • quantities change only by typing: a number field steps its value on a
//    mouse-wheel / trackpad scroll or an Arrow key while focused (a scan focuses
//    it), which silently turned a saved 3 into 4 and marked it as entered. Those
//    gestures are blocked here; the page still scrolls.
export default class extends Controller {
  static targets = ["progressBar", "counted", "remaining", "total", "percent", "filterButton"]

  connect() {
    this.filterMode = "all"
    this.element.querySelectorAll("[data-quantity-field]").forEach((input) => this.#applyDifference(input))
    this.#refreshProgress()
    this.blockWheel = this.#blockWheel.bind(this)
    this.blockArrows = this.#blockArrows.bind(this)
    this.element.addEventListener("wheel", this.blockWheel, { passive: false })
    this.element.addEventListener("keydown", this.blockArrows)
  }

  disconnect() {
    this.element.removeEventListener("wheel", this.blockWheel)
    this.element.removeEventListener("keydown", this.blockArrows)
  }

  recalc(event) {
    const input = event.target
    // Typing in a row is an explicit entry: the server records it as a fresh
    // physical count, even if the value equals the previous one.
    this.#markEntered(input.closest("[data-line-row]"))
    this.#applyDifference(input)
    this.#applyFilter(input.closest("[data-line-row]"))
    this.#refreshProgress()
  }

  // "Confirm count" on an unverified / system row: the shown quantity was
  // physically counted — recorded on save exactly as if it had been typed.
  confirmRow(event) {
    const row = event.currentTarget.closest("[data-line-row]")
    const input = row?.querySelector("[data-quantity-field]")
    if (!input) return
    if (input.value.trim() === "") { input.focus(); return }
    this.#markEntered(row)
    this.#applyDifference(input)
    this.#refreshProgress()
  }

  // "Save & Complete": before Turbo asks for confirmation, say how many
  // products were not physically counted (untouched unverified / system rows)
  // and will therefore use their system quantity at completion.
  confirmComplete(event) {
    const button = event.currentTarget
    const pending = this.#rows().filter((row) =>
      row.dataset.unverified === "true" && row.querySelector("[data-entered-flag]")?.value !== "1").length
    button.dataset.turboConfirm = pending > 0
      ? button.dataset.confirmSome.replace("__COUNT__", pending)
      : button.dataset.confirmNone
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
  #markEntered(row) {
    if (!row) return
    const flag = row.querySelector("[data-entered-flag]")
    if (flag) flag.value = "1"
    const status = row.querySelector("[data-entry-status]")
    if (status) {
      status.hidden = false
      status.textContent = status.dataset.enteredLabel
      status.classList.remove("badge-warning", "badge-neutral")
      status.classList.add("badge-success")
    }
    row.querySelector("[data-confirm-row]")?.setAttribute("hidden", "")
  }

  // Scrolling over a focused quantity field scrolls the page instead of
  // stepping the value.
  #blockWheel(event) {
    const field = event.target.closest?.("[data-quantity-field]")
    if (!field || document.activeElement !== field) return
    event.preventDefault()
    window.scrollBy(event.deltaX, event.deltaY)
  }

  // Arrow Up / Down never step a quantity.
  #blockArrows(event) {
    if (event.key !== "ArrowUp" && event.key !== "ArrowDown") return
    if (event.target.closest?.("[data-quantity-field]")) event.preventDefault()
  }

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
