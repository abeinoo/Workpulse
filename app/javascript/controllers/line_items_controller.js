import { Controller } from "@hotwired/stimulus"

// Dynamic add/remove of nested line-item rows on goods-receipt and stock-issue
// forms. A <template> holds the new-row HTML with NEW_INDEX as the param-key
// placeholder; on add it's replaced with Date.now() for a unique key Rails
// accepts. Persisted rows are soft-removed via their _destroy hidden input.
export default class extends Controller {
  static targets = ["rows", "template", "emptyState"]

  add() {
    const html = this.templateTarget.innerHTML.replace(/NEW_INDEX/g, Date.now())
    this.rowsTarget.insertAdjacentHTML("beforeend", html)
    this.#updateEmptyState()
  }

  remove(event) {
    const row = event.currentTarget.closest("[data-line-row]")
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
    const visible = this.rowsTarget.querySelectorAll("[data-line-row]:not([hidden])")
    this.emptyStateTarget.hidden = visible.length > 0
  }
}
