import { Controller } from "@hotwired/stimulus"

// Minimal collapsible: toggles aria-expanded on trigger and hidden on content.
// Usage: data-controller="collapsible" data-collapsible-open-value="true|false"
export default class extends Controller {
  static targets = ["trigger", "content"]
  static values  = { open: { type: Boolean, default: false } }

  connect() {
    this.#apply(this.openValue)
  }

  toggle() {
    this.openValue = !this.openValue
    this.#apply(this.openValue)
  }

  #apply(open) {
    this.contentTargets.forEach(el => {
      el.hidden = !open
    })
    this.triggerTargets.forEach(el => {
      el.setAttribute("aria-expanded", open ? "true" : "false")
    })
    this.element.classList.toggle("collapsible--open", open)
  }
}
