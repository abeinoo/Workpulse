import { Controller } from "@hotwired/stimulus"

// Minimal collapsible: toggles aria-expanded on trigger and hidden on content.
// Usage: data-controller="collapsible" data-collapsible-open-value="true|false"
//
// Optional accordion behavior: give every instance that should mutually
// exclude the others a shared data-collapsible-group-value="some-name" —
// opening one broadcasts a "collapsible:opened" event on document that every
// other instance sharing that group listens for and closes itself in
// response. Instances with no group value (the default, "") are unaffected —
// existing single-instance disclosures elsewhere on the page keep behaving
// exactly as before.
export default class extends Controller {
  static targets = ["trigger", "content"]
  static values  = { open: { type: Boolean, default: false }, group: { type: String, default: "" } }

  connect() {
    this.#apply(this.openValue)
    if (this.groupValue) {
      this.onSiblingOpened = (event) => {
        if (event.detail.group === this.groupValue && event.detail.source !== this.element) {
          this.openValue = false
          this.#apply(false)
        }
      }
      document.addEventListener("collapsible:opened", this.onSiblingOpened)
    }
  }

  disconnect() {
    if (this.onSiblingOpened) document.removeEventListener("collapsible:opened", this.onSiblingOpened)
  }

  toggle() {
    this.openValue = !this.openValue
    this.#apply(this.openValue)
    if (this.openValue && this.groupValue) {
      document.dispatchEvent(new CustomEvent("collapsible:opened", { detail: { group: this.groupValue, source: this.element } }))
    }
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
