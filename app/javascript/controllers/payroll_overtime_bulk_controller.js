import { Controller } from "@hotwired/stimulus"

// Drives the "Adjust Overtime" bulk action on the payroll period page.
//
//   1. Show / hide the sticky action bar as entry checkboxes are toggled.
//   2. Keep the "X selected" count and select-all master checkbox in sync.
//   3. Open a modal to choose the mode (zero / fixed amount / fixed minutes /
//      restore), an optional value, and a required reason.
//   4. Inject one hidden entry_ids[] input per selected row, then submit.
export default class extends Controller {
  static targets = [
    "actionBar", "countBadge", "modal", "ids",
    "modalCount", "value", "valueField", "reason",
  ]

  connect() {
    this._syncBar()
    this._onKeydown = this._handleKeydown.bind(this)
    document.addEventListener("keydown", this._onKeydown)
  }

  disconnect() {
    document.removeEventListener("keydown", this._onKeydown)
  }

  get allBoxes() {
    return Array.from(this.element.querySelectorAll(".ot-bulk-row"))
  }

  get checkedBoxes() {
    return this.allBoxes.filter((b) => b.checked)
  }

  toggleAll(event) {
    const checked = event.target.checked
    this.allBoxes.forEach((b) => { b.checked = checked })
    this._syncBar()
  }

  rowChanged() {
    const master = this.element.querySelector(".ot-bulk-all")
    if (master) {
      const all = this.allBoxes
      const checked = this.checkedBoxes
      master.checked = all.length > 0 && checked.length === all.length
      master.indeterminate = checked.length > 0 && checked.length < all.length
    }
    this._syncBar()
  }

  _syncBar() {
    const count = this.checkedBoxes.length
    if (this.hasActionBarTarget) this.actionBarTarget.style.display = count > 0 ? "" : "none"
    if (this.hasCountBadgeTarget) this.countBadgeTarget.textContent = count
  }

  // Show / hide the value field depending on the chosen mode.
  modeChanged(event) {
    const mode = event.target.value
    const needsValue = mode === "fixed_amount" || mode === "fixed_minutes"
    if (this.hasValueFieldTarget) this.valueFieldTarget.style.display = needsValue ? "" : "none"
  }

  openModal() {
    const boxes = this.checkedBoxes
    if (boxes.length === 0) return

    if (this.hasIdsTarget) {
      this.idsTarget.innerHTML = boxes
        .map((b) => `<input type="hidden" name="entry_ids[]" value="${b.value}">`)
        .join("")
    }
    if (this.hasModalCountTarget) this.modalCountTarget.textContent = boxes.length
    if (this.hasModalTarget) {
      this.modalTarget.style.display = ""
      requestAnimationFrame(() => {
        const first = this.modalTarget.querySelector("select, input, textarea, button")
        if (first) first.focus()
      })
    }
  }

  closeModal() {
    if (this.hasModalTarget) this.modalTarget.style.display = "none"
  }

  overlayClick(event) {
    if (event.target === this.modalTarget) this.closeModal()
  }

  _handleKeydown(event) {
    if (!this.hasModalTarget || this.modalTarget.style.display === "none") return
    if (event.key === "Escape") this.closeModal()
  }
}
