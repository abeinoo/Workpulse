import { Controller } from "@hotwired/stimulus"

// Toggles the "Paid from my balance/custody" panel on the New/Edit Expense
// form based on the selected Payment Type — it only applies to a Direct
// expense; an Installment expense's payment source is decided per payment,
// later. Mirrors funding_source_controller.js's goods-receipt pattern.
export default class extends Controller {
  static targets = ["typeRadio", "panel"]

  connect() {
    this.toggle()
  }

  toggle() {
    const checked = this.typeRadioTargets.find((radio) => radio.checked)
    const isDirect = checked?.value === "direct"
    this.panelTarget.classList.toggle("hidden", !isDirect)
    this.panelTarget.hidden = !isDirect

    if (!isDirect) {
      const checkbox = this.panelTarget.querySelector('input[type="checkbox"]')
      if (checkbox) checkbox.checked = false
    }
  }
}
