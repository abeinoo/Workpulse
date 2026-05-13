import { Controller } from "@hotwired/stimulus"

// Manages the dynamic add/remove of nested penalty rule rows in the shift form.
// Uses a <template> element whose innerHTML contains the new-row HTML with
// NEW_INDEX as a placeholder. On add, replaces NEW_INDEX with Date.now() so
// each new row gets a unique param key Rails will accept.
export default class extends Controller {
  static targets = ["rulesContainer", "template", "emptyState"]

  addRule() {
    const html = this.templateTarget.innerHTML.replace(/NEW_INDEX/g, Date.now())
    this.rulesContainerTarget.insertAdjacentHTML("beforeend", html)
    this.#updateEmptyState()
  }

  removeRule(event) {
    const row = event.currentTarget.closest("[data-rule-row]")
    const destroyInput = row.querySelector("input[data-destroy-field]")

    if (destroyInput) {
      // Persisted record: mark for destruction, hide the row
      destroyInput.value = "1"
      row.hidden = true
    } else {
      // New (unsaved) record: remove from DOM entirely
      row.remove()
    }

    this.#updateEmptyState()
  }

  #updateEmptyState() {
    if (!this.hasEmptyStateTarget) return
    const visibleRows = this.rulesContainerTarget.querySelectorAll("[data-rule-row]:not([hidden])")
    this.emptyStateTarget.hidden = visibleRows.length > 0
  }
}
