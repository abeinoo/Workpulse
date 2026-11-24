import { Controller } from "@hotwired/stimulus"

// Single-product Quick Issue popup (inventory/quick_issues/_dialog).
// Presentation only — Inventory::StockIssueQuickIssue enforces every rule
// server-side (warehouse authorization, availability again under lock).
//
//  - With several authorized warehouses, the quantity available is shown for
//    the selected one, from the figures the server rendered on each <option>
//    (data-available / data-available-label); the quantity's max and the
//    Confirm button follow it. With one warehouse there is no selector and
//    the server-rendered figure stands.
//  - Notes is the only free-text field: optional, but required — with a hint
//    saying the reason must be explained there — when "Other" is selected.
export default class extends Controller {
  static targets = ["warehouse", "availability", "availableText", "sourceText", "quantity", "submit",
                    "reason", "note", "noteLabel", "noteHint"]
  static values = { units: String, availableIn: String }

  connect() {
    this.reasonChanged()
  }

  warehouseChanged() {
    if (!this.hasWarehouseTarget || !this.hasAvailabilityTarget) return

    const option = this.warehouseTarget.selectedOptions[0]
    if (!option || option.value === "") {
      this.availabilityTarget.hidden = true
      this.#block(true)
      return
    }

    const { available, availableLabel } = option.dataset
    const blocked = !(Number.parseFloat(available || "0") > 0)

    this.availabilityTarget.hidden = false
    this.availabilityTarget.classList.toggle("qi__availability--empty", blocked)
    this.availableTextTarget.textContent = `${availableLabel} ${this.unitsValue}`
    this.sourceTextTarget.textContent = this.availableInValue.replace("%{warehouse}", option.textContent.trim())
    if (this.hasQuantityTarget) {
      if (blocked) this.quantityTarget.removeAttribute("max")
      else this.quantityTarget.max = available
    }
    this.#block(blocked)
  }

  reasonChanged() {
    if (!this.hasReasonTarget || !this.hasNoteTarget) return

    const other = this.reasonTarget.value === "other"
    this.noteTarget.required = other
    if (this.hasNoteLabelTarget) this.noteLabelTarget.classList.toggle("form-label--required", other)
    if (this.hasNoteHintTarget) {
      const hint = this.noteHintTarget
      hint.textContent = other ? hint.dataset.otherText : hint.dataset.optionalText
      hint.classList.toggle("form-hint--info", other)
    }
  }

  #block(blocked) {
    if (this.hasSubmitTarget) this.submitTarget.disabled = blocked
  }
}
