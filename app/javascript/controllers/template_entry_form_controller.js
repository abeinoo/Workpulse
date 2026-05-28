import { Controller } from "@hotwired/stimulus"

// Manages dynamic add/remove of nested ShiftTemplateEntry rows in the
// template form. Mirrors the penalty_rules_controller pattern.
export default class extends Controller {
  static targets = ["entriesContainer", "template", "emptyState"]

  addEntry() {
    const html = this.templateTarget.innerHTML.replace(/NEW_INDEX/g, Date.now())
    this.entriesContainerTarget.insertAdjacentHTML("beforeend", html)
    this.#updateEmptyState()
  }

  removeEntry(event) {
    const row = event.currentTarget.closest("[data-entry-row]")
    const destroyInput = row.querySelector("input[data-destroy-field]")

    if (destroyInput) {
      destroyInput.value = "1"
      row.hidden = true
    } else {
      row.remove()
    }

    this.#updateEmptyState()
  }

  #updateEmptyState() {
    if (!this.hasEmptyStateTarget) return
    const visible = this.entriesContainerTarget.querySelectorAll("[data-entry-row]:not([hidden])")
    this.emptyStateTarget.hidden = visible.length > 0
  }
}
