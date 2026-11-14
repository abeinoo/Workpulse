import { Controller } from "@hotwired/stimulus"

// Live "الإجمالي" preview on a line-items form: quantity × unit cost per row,
// display only (the server computes and stores the real total). Rows are
// found through the same markers line-items uses ([data-line-row]) plus
// [data-quantity-field] / [data-cost-field] / [data-line-total], so rows added
// from the template are picked up without extra wiring. Formatting matches
// purchase_request_form_controller (2 decimals, currency prefix/suffix).
//
// Usage: data-controller="line-total" data-action="input->line-total#recalculate"
//        data-line-total-currency-prefix-value / -suffix-value
// Optional: a data-line-total-target="grandTotal" element shows the sum of the
// rows (still display only).
export default class extends Controller {
  static targets = ["grandTotal"]
  static values = { currencyPrefix: String, currencySuffix: String }

  connect() {
    this.recalculate()
  }

  recalculate() {
    let sum = 0
    let any = false
    this.element.querySelectorAll("[data-line-row]").forEach((row) => {
      const cell = row.querySelector("[data-line-total]")
      if (!cell) return

      const qty  = parseFloat(row.querySelector("[data-quantity-field]")?.value)
      const cost = parseFloat(row.querySelector("[data-cost-field]")?.value)
      const valid = Number.isFinite(qty) && Number.isFinite(cost)
      cell.textContent = valid ? this.#format(qty * cost) : "—"
      // A removed row (line-items hides it) never counts.
      if (valid && !row.hidden) { sum += qty * cost; any = true }
    })
    if (this.hasGrandTotalTarget) this.grandTotalTarget.textContent = any ? this.#format(sum) : "—"
  }

  #format(value) {
    const num = value.toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 })
    return `${this.currencyPrefixValue}${num}${this.currencySuffixValue}`
  }
}
