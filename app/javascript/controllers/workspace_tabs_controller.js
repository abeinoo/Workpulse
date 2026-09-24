import { Controller } from "@hotwired/stimulus"

// Horizontally scrolling workspace tab strip (e.g. the Inventory workspace):
// keeps the active tab in view by centring it inside the strip.
//
// Uses a measured scrollBy() delta rather than scrollLeft or scrollIntoView():
// scrollLeft is negative/reversed in RTL, and scrollIntoView() may also scroll
// the window. getBoundingClientRect() + scrollBy() are physical in both
// directions, so the same maths is correct in LTR and RTL.
export default class extends Controller {
  connect() {
    // Wait a frame so layout (fonts, widths) has settled before measuring.
    this._frame = requestAnimationFrame(() => this.revealActive())
    // Tab widths can still change once web fonts finish loading — re-check then.
    document.fonts?.ready.then(() => { if (this.element.isConnected) this.revealActive() })
  }

  disconnect() {
    cancelAnimationFrame(this._frame)
  }

  revealActive() {
    const active = this.element.querySelector(".is-active")
    if (!active) return

    const strip = this.element.getBoundingClientRect()
    const tab = active.getBoundingClientRect()
    const fullyVisible = tab.left >= strip.left && tab.right <= strip.right
    if (fullyVisible) return

    const delta = (tab.left + tab.width / 2) - (strip.left + strip.width / 2)
    this.element.scrollBy({ left: delta, behavior: "instant" })
  }
}
