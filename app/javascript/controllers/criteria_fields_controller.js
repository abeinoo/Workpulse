import { Controller } from "@hotwired/stimulus"

// Dynamic add/remove of evaluation criterion rows on the template form.
// Mirrors the penalty-rules pattern: a <template> holds the new-row markup with
// NEW_INDEX placeholders replaced by a timestamp so each row gets a unique key.
export default class extends Controller {
  static targets = ["container", "template", "emptyState"]

  add() {
    const html = this.templateTarget.innerHTML.replace(/NEW_INDEX/g, Date.now())
    this.containerTarget.insertAdjacentHTML("beforeend", html)
    this.#updateEmptyState()
  }

  remove(event) {
    const row = event.currentTarget.closest("[data-criterion-row]")
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
    const visible = this.containerTarget.querySelectorAll("[data-criterion-row]:not([hidden])")
    this.emptyStateTarget.hidden = visible.length > 0
  }
}
