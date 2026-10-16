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
export default class extends Controller {
  static values = { currencyPrefix: String, currencySuffix: String }

  connect() {
    this.recalculate()
  }

  recalculate() {
    this.element.querySelectorAll("[data-line-row]").forEach((row) => {
      const cell = row.querySelector("[data-line-total]")
      if (!cell) return

      const qty  = parseFloat(row.querySelector("[data-quantity-field]")?.value)
      const cost = parseFloat(row.querySelector("[data-cost-field]")?.value)
      cell.textContent = Number.isFinite(qty) && Number.isFinite(cost) ? this.#format(qty * cost) : "—"
    })
  }

  #format(value) {
    const num = value.toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 })
    return `${this.currencyPrefixValue}${num}${this.currencySuffixValue}`
  }
}
