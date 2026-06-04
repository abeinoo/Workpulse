import { Controller } from "@hotwired/stimulus"

// Drives the "Mark Selected as Paid" bulk action on the employee-requests index.
//
// Responsibilities:
//   1. Show / hide the sticky bulk-action bar as advance checkboxes are toggled.
//   2. Keep the "X selected" count badge current and maintain the select-all
//      master checkbox (checked / indeterminate) over the filtered rows.
//   3. Open a confirmation modal showing the selected count, total amount,
//      a payment-date field (default today) and an optional notes field.
//   4. Inject one hidden request_ids[] input per selected row, then submit.
//   5. Accessibility: ESC closes the modal; focus is trapped inside it.
export default class extends Controller {
  static targets = [
    "actionBar",
    "countBadge",
    "markPaidBtn",
    "modal",
    "ids",
    "modalCount",
    "modalTotal",
  ]

  static values = {
    currencyPrefix: String,
    currencySuffix: String,
  }

  connect() {
    this._syncBar()
    this._onKeydown = this._handleKeydown.bind(this)
    document.addEventListener("keydown", this._onKeydown)
  }

  disconnect() {
    document.removeEventListener("keydown", this._onKeydown)
  }

  // ── Checkbox state ─────────────────────────────────────────────────────────

  get allBoxes() {
    return Array.from(this.element.querySelectorAll(".bulk-check-row"))
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
    const master = this.element.querySelector(".bulk-check-all")
    if (master) {
      const all     = this.allBoxes
      const checked = this.checkedBoxes
      master.checked       = all.length > 0 && checked.length === all.length
      master.indeterminate = checked.length > 0 && checked.length < all.length
    }
    this._syncBar()
  }

  _syncBar() {
    const count  = this.checkedBoxes.length
    const hasAny = count > 0

    if (this.hasActionBarTarget) {
      this.actionBarTarget.style.display = hasAny ? "" : "none"
    }
    if (this.hasCountBadgeTarget) {
      this.countBadgeTarget.textContent = count
    }
    if (this.hasMarkPaidBtnTarget) {
      this.markPaidBtnTarget.disabled = !hasAny
      this.markPaidBtnTarget.setAttribute("aria-disabled", hasAny ? "false" : "true")
    }
  }

  // ── Selected totals ──────────────────────────────────────────────────────

  get selectedTotal() {
    return this.checkedBoxes.reduce(
      (sum, b) => sum + (parseFloat(b.dataset.amount) || 0),
      0
    )
  }

  // ── Modal ──────────────────────────────────────────────────────────────────

  openModal() {
    const boxes = this.checkedBoxes
    if (boxes.length === 0) return

    if (this.hasIdsTarget) {
      this.idsTarget.innerHTML = boxes
        .map((b) => `<input type="hidden" name="request_ids[]" value="${b.value}">`)
        .join("")
    }
    if (this.hasModalCountTarget) {
      this.modalCountTarget.textContent = boxes.length
    }
    if (this.hasModalTotalTarget) {
      this.modalTotalTarget.textContent = this._formatCurrency(this.selectedTotal)
    }

    if (this.hasModalTarget) {
      this.modalTarget.style.display = ""
      requestAnimationFrame(() => {
        const card  = this.modalTarget.querySelector(".modal-card")
        const first = card && card.querySelector('input[type="date"], textarea, button')
        if (first) first.focus()
      })
    }
  }

  closeModal() {
    if (this.hasModalTarget) this.modalTarget.style.display = "none"
    if (this.hasMarkPaidBtnTarget) this.markPaidBtnTarget.focus()
  }

  overlayClick(event) {
    if (event.target === this.modalTarget) this.closeModal()
  }

  _handleKeydown(event) {
    if (!this.hasModalTarget || this.modalTarget.style.display === "none") return

    if (event.key === "Escape") {
      this.closeModal()
      return
    }
    if (event.key === "Tab") {
      const card = this.modalTarget.querySelector(".modal-card")
      if (!card) return
      const focusable = Array.from(
        card.querySelectorAll(
          'a[href], button:not([disabled]), input, select, textarea, [tabindex]:not([tabindex="-1"])'
        )
      )
      if (focusable.length === 0) return
      const first = focusable[0]
      const last  = focusable[focusable.length - 1]
      if (event.shiftKey && document.activeElement === first) {
        event.preventDefault()
        last.focus()
      } else if (!event.shiftKey && document.activeElement === last) {
        event.preventDefault()
        first.focus()
      }
    }
  }

  // Formats a number to match the server's format_currency helper (precision 0).
  _formatCurrency(value) {
    const num = Math.round(value).toLocaleString("en-US")
    return `${this.currencyPrefixValue}${num}${this.currencySuffixValue}`
  }
}
