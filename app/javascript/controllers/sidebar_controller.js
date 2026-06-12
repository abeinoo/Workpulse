import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["sidebar", "overlay"]

  connect() {
    // Close the drawer automatically when Turbo navigates to a new page
    this._onVisit = () => this.close()
    document.addEventListener("turbo:visit", this._onVisit)

    // Keep the active item visible and its parent group expanded. connect()
    // fires on the initial load, on each Turbo render, and on cached-snapshot
    // restores, so this corrects any stale collapsed/scrolled state that Turbo
    // may briefly paint before the fresh sidebar lands.
    this.revealActiveItem()
  }

  disconnect() {
    document.removeEventListener("turbo:visit", this._onVisit)
  }

  toggle() {
    this.sidebarTarget.classList.toggle("is-open")
    this.overlayTarget.classList.toggle("is-visible")
  }

  close() {
    this.sidebarTarget.classList.remove("is-open")
    this.overlayTarget.classList.remove("is-visible")
  }

  // Expands the collapsible group that holds the active link (Inventory,
  // Performance, Administration, …) and scrolls it into view inside the nav.
  // Works for every grouped section because it keys off the rendered
  // `.is-active` item rather than any per-section logic.
  revealActiveItem() {
    const active = this.element.querySelector(".sidebar__nav-item.is-active")
    if (!active) return

    // Force the parent <details> group open even if a cached snapshot left it
    // collapsed; the server already sets `open`, this guards the preview flash.
    const group = active.closest("details.sidebar__group")
    if (group && !group.open) group.open = true

    const scroller = active.closest(".sidebar__nav")
    if (!scroller) return

    // Defer so the <details> expansion has been laid out before we measure.
    requestAnimationFrame(() => {
      const itemRect = active.getBoundingClientRect()
      const navRect = scroller.getBoundingClientRect()
      const fullyVisible =
        itemRect.top >= navRect.top && itemRect.bottom <= navRect.bottom
      if (fullyVisible) return

      // Centre the active item within the scrollable nav, touching only the
      // nav's own scrollTop (never the window).
      const offset = itemRect.top - navRect.top
      scroller.scrollTop +=
        offset - scroller.clientHeight / 2 + itemRect.height / 2
    })
  }
}
