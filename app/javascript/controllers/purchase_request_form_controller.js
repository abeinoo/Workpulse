import { Controller } from "@hotwired/stimulus"

// Live line-total / grand-total recalculation on the Purchase Request edit
// form (draft only — see PurchaseRequestPolicy#update?). Pure display: the
// authoritative total is always recomputed server-side
// (PurchaseRequestItem#compute_total_cost / PurchaseRequest#total_amount) —
// this only keeps the on-screen numbers honest while the user edits.
export default class extends Controller {
  static targets = ["row", "lineTotal", "grandTotal"]
  static values = { currencyPrefix: String, currencySuffix: String }

  connect() {
    this.recalculate()
  }

  recalculate() {
    let grandTotal = 0

    this.rowTargets.forEach((row) => {
      if (row.hidden) return

      const qty   = parseFloat(row.querySelector("[data-quantity-field]")?.value) || 0
      const price = parseFloat(row.querySelector("[data-price-field]")?.value) || 0
      const total = qty * price
      grandTotal += total

      const cell = row.querySelector('[data-purchase-request-form-target="lineTotal"]')
      if (cell) cell.textContent = this._formatCurrency(total)
    })

    if (this.hasGrandTotalTarget) this.grandTotalTarget.textContent = this._formatCurrency(grandTotal)
  }

  _formatCurrency(value) {
    const num = value.toLocaleString("en-US", {
      minimumFractionDigits: 2,
      maximumFractionDigits: 2,
    })
    return `${this.currencyPrefixValue}${num}${this.currencySuffixValue}`
  }
}
