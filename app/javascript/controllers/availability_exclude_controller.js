import { Controller } from "@hotwired/stimulus"

// A branch card's "Exclude this product from this branch" checkbox. Ticking
// (or, on an excluded card, unticking) never writes anything by itself: it
// reveals the confirmation below — the exclusion reason and dependency
// summary, or "Include again" — and hides it when the box is put back.
export default class extends Controller {
  static targets = ["checkbox", "panel"]
  // true after a refused exclusion: the panel re-opens with the reason kept.
  static values = { pending: Boolean }

  connect() {
    if (this.pendingValue) this.checkboxTarget.checked = !this.checkboxTarget.defaultChecked
    this.sync()
  }

  sync() {
    const changed = this.checkboxTarget.checked !== this.checkboxTarget.defaultChecked
    this.panelTargets.forEach((panel) => {
      panel.hidden = !changed
      // Load the confirmation now (not only when scrolled into view).
      if (changed) panel.querySelectorAll("turbo-frame[loading='lazy']").forEach((frame) => frame.setAttribute("loading", "eager"))
    })
    this.element.classList.toggle("availability-card--pending-exclusion", changed)
  }
}
