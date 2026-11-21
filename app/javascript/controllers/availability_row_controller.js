import { Controller } from "@hotwired/stimulus"

// One warehouse card in the product's availability section: its low-stock
// level / reorder quantity / alerts fields save together with the card's
// Save button. Save stays disabled until a value differs from the stored one
// (so nothing is resubmitted unchanged), and the card is marked as having
// unsaved changes.
export default class extends Controller {
  static targets = ["field", "save"]

  connect() { this.sync() }

  sync() {
    const dirty = this.fieldTargets.some((field) =>
      field.type === "checkbox" ? field.checked !== field.defaultChecked : field.value !== field.defaultValue)
    this.element.classList.toggle("availability-card--dirty", dirty)
    this.saveTargets.forEach((button) => { button.disabled = !dirty })
  }
}
