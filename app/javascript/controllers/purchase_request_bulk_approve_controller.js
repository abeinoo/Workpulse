import { Controller } from "@hotwired/stimulus"

// "اعتماد الطلبات المحددة" on the Purchase Requests index.
//
//   1. Checkbox selection over the CURRENT page only. Only rows the server
//      marked eligible (pending approval, approvable by this user) have an
//      enabled checkbox; the header checkbox toggles exactly those, with an
//      indeterminate state for a partial selection.
//   2. A bulk bar with the selected count and the combined total. Amounts come
//      from each request's server-computed total (data-amount, a decimal
//      string) and are summed as fixed-point integers — never floats.
//   3. A confirmation modal; on confirm, one hidden purchase_request_ids[]
//      input per selected row is injected and ONE form POST goes to
//      bulk_approve. The server re-checks everything under lock.
//
// Selection always starts empty on connect, so a page/filter change (a new
// page load) or a Turbo-cached snapshot never carries stale ids.
const SCALE = 4 // purchase_request_items.total_cost scale

export default class extends Controller {
  static targets = [
    "actionBar", "countBadge", "totalBadge", "approveBtn",
    "modal", "ids", "modalBody", "confirmBtn",
  ]

  static values = {
    currencySymbol: String,
    symbolAfter: Boolean,
    modalBody: String,
  }

  connect() {
    this.rowBoxes.forEach((b) => { b.checked = false })
    if (this.masterBox) this.masterBox.checked = false
    this._sync()
    this._onKeydown = this._handleKeydown.bind(this)
    document.addEventListener("keydown", this._onKeydown)
  }

  disconnect() {
    document.removeEventListener("keydown", this._onKeydown)
  }

  // ── Selection ────────────────────────────────────────────────────────────

  get rowBoxes() {
    return Array.from(this.element.querySelectorAll(".pr-bulk-check-row:not([disabled])"))
  }

  get checkedBoxes() {
    return this.rowBoxes.filter((b) => b.checked)
  }

  get masterBox() {
    return this.element.querySelector(".pr-bulk-check-all")
  }

  toggleAll(event) {
    const checked = event.target.checked
    this.rowBoxes.forEach((b) => { b.checked = checked })
    this._sync()
  }

  rowChanged() {
    this._sync()
  }

  clear() {
    this.rowBoxes.forEach((b) => { b.checked = false })
    this._sync()
  }

  _sync() {
    const all     = this.rowBoxes
    const checked = this.checkedBoxes
    const count   = checked.length

    if (this.masterBox) {
      this.masterBox.checked       = all.length > 0 && count === all.length
      this.masterBox.indeterminate = count > 0 && count < all.length
      this.masterBox.disabled      = all.length === 0
    }
    if (this.hasActionBarTarget) this.actionBarTarget.style.display = count > 0 ? "" : "none"
    if (this.hasCountBadgeTarget) this.countBadgeTarget.textContent = count
    if (this.hasTotalBadgeTarget) this.totalBadgeTarget.textContent = this._formatCurrency(this._selectedUnits())
    if (this.hasApproveBtnTarget) this.approveBtnTarget.disabled = count === 0
  }

  // ── Fixed-point money ────────────────────────────────────────────────────

  // "2200.5" -> 22005000n (SCALE decimal places). Non-numeric -> 0n.
  _toUnits(value) {
    const str = String(value ?? "").trim()
    if (!/^-?\d+(\.\d+)?$/.test(str)) return 0n
    const negative = str.startsWith("-")
    const [intPart, fracPart = ""] = str.replace("-", "").split(".")
    const units = BigInt(intPart) * 10n ** BigInt(SCALE) + BigInt((fracPart + "0".repeat(SCALE)).slice(0, SCALE))
    return negative ? -units : units
  }

  _selectedUnits() {
    return this.checkedBoxes.reduce((sum, b) => sum + this._toUnits(b.dataset.amount), 0n)
  }

  // Same output as the server's format_currency (precision 2, "," grouping,
  // symbol before in EN / after in AR); rounds half up from SCALE to 2.
  _formatCurrency(units) {
    const step  = 10n ** BigInt(SCALE - 2)
    const cents = (units + step / 2n) / step
    const whole = (cents / 100n).toString().replace(/\B(?=(\d{3})+(?!\d))/g, ",")
    const num   = `${whole}.${(cents % 100n).toString().padStart(2, "0")}`
    return this.symbolAfterValue ? `${num} ${this.currencySymbolValue}` : `${this.currencySymbolValue} ${num}`
  }

  // ── Confirmation modal ───────────────────────────────────────────────────

  openModal() {
    const boxes = this.checkedBoxes
    if (boxes.length === 0) return // never post an empty selection

    if (this.hasIdsTarget) {
      this.idsTarget.innerHTML = boxes
        .map((b) => `<input type="hidden" name="purchase_request_ids[]" value="${encodeURIComponent(b.value)}">`)
        .join("")
    }
    if (this.hasModalBodyTarget) {
      this.modalBodyTarget.textContent = this.modalBodyValue
        .replace("%{count}", boxes.length)
        .replace("%{total}", this._formatCurrency(this._selectedUnits()))
    }
    if (this.hasConfirmBtnTarget) this.confirmBtnTarget.disabled = false
    if (this.hasModalTarget) {
      this.modalTarget.style.display = ""
      requestAnimationFrame(() => this.confirmBtnTarget?.focus())
    }
  }

  closeModal() {
    if (this.hasModalTarget) this.modalTarget.style.display = "none"
    if (this.hasApproveBtnTarget) this.approveBtnTarget.focus()
  }

  overlayClick(event) {
    if (event.target === this.modalTarget) this.closeModal()
  }

  // Guards against a double submit while the POST is in flight.
  submit(event) {
    if (this.checkedBoxes.length === 0) {
      event.preventDefault()
      return
    }
    if (this.hasConfirmBtnTarget) this.confirmBtnTarget.disabled = true
  }

  _handleKeydown(event) {
    if (!this.hasModalTarget || this.modalTarget.style.display === "none") return
    if (event.key === "Escape") this.closeModal()
  }
}
