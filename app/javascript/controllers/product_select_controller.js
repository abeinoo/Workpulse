import { Controller } from "@hotwired/stimulus"

// Bulk product selection on the products index page.
// Manages checkboxes, select-all, and the "Print Selected Barcodes" action.
export default class extends Controller {
  static targets = ["checkbox", "selectAll", "printBtn", "printCount"]

  toggleAll(event) {
    this.checkboxTargets.forEach(cb => { cb.checked = event.target.checked })
    this.#sync()
  }

  toggle() {
    this.#sync()
  }

  printSelected(event) {
    const ids = this.checkboxTargets.filter(cb => cb.checked).map(cb => cb.dataset.productId)
    if (ids.length === 0) {
      event.preventDefault()
      return
    }
    const base = event.currentTarget.dataset.printUrl
    const url  = new URL(base, window.location.origin)
    ids.forEach(id => url.searchParams.append("product_ids[]", id))
    window.open(url.toString(), "_blank", "noopener")
  }

  #sync() {
    const total   = this.checkboxTargets.length
    const checked = this.checkboxTargets.filter(cb => cb.checked).length

    if (this.hasSelectAllTarget) {
      this.selectAllTarget.checked       = checked === total && total > 0
      this.selectAllTarget.indeterminate = checked > 0 && checked < total
    }

    if (this.hasPrintBtnTarget) {
      this.printBtnTarget.disabled = checked === 0
    }

    if (this.hasPrintCountTarget) {
      this.printCountTarget.textContent = checked > 0 ? `(${checked})` : ""
    }
  }
}
