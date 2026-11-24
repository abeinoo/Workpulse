import { Controller } from "@hotwired/stimulus"

// The product form's Unit of Measure + Amount (inventory/products/_form): the
// Amount follows the selected unit, without a reload.
//   * pieces — Amount hidden and cleared; a blank is submitted instead, so a
//     whole product never keeps a stale amount;
//   * others — Amount shown with the unit as its suffix (ml, g, cm …).
// No conversion: changing the unit changes only these two fields.
export default class extends Controller {
  static targets = ["select", "amountGroup", "amount", "suffix", "amountBlank"]

  connect() { this.change() }

  change() {
    const unit = this.selectTarget.value
    const pieces = unit === "pieces"
    this.amountGroupTarget.hidden = pieces
    this.amountTarget.disabled = pieces
    if (pieces) this.amountTarget.value = ""
    this.amountBlankTarget.disabled = !pieces
    this.suffixTarget.textContent = this.#short(unit)
  }

  #short(unit) {
    const option = Array.from(this.selectTarget.options).find((o) => o.value === unit)
    return option?.dataset.short || unit
  }
}
