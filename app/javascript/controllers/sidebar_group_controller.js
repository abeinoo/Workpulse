import { Controller } from "@hotwired/stimulus"

// Enhances a native <details class="sidebar__group"> disclosure (see
// _sidebar_group.html.erb): native <details>/<summary> already gives free
// keyboard support and full-row click handling, so this controller only
// adds the two things the native element doesn't provide on its own —
//
//   1. aria-expanded on the <summary>, kept in sync with the element's own
//      `open` state (native <details> does not manage this attribute).
//   2. Remembering the user's manual expand/collapse choice in
//      sessionStorage so it survives Turbo navigation, WITHOUT ever
//      overriding a group the server rendered open because it holds the
//      active page (see the `active` value — computed server-side from the
//      same is-active conditions the child links already use, never
//      re-derived here).
export default class extends Controller {
  static targets = ["summary"]
  static values  = { key: String, active: Boolean }

  connect() {
    if (this.activeValue) {
      // Refresh storage so a later, inactive page still remembers this was
      // left open — the active page's group must never appear collapsed,
      // even if the user had previously collapsed it manually elsewhere.
      sessionStorage.setItem(this.#storageKey, "true")
    } else {
      const stored = sessionStorage.getItem(this.#storageKey)
      if (stored !== null) this.element.open = stored === "true"
    }
    this.#syncAria()
  }

  // Bound to the <details> element's native `toggle` event (fires whenever
  // the user opens/closes it via the summary, mouse or keyboard alike).
  onToggle() {
    sessionStorage.setItem(this.#storageKey, this.element.open ? "true" : "false")
    this.#syncAria()
  }

  #syncAria() {
    this.summaryTarget.setAttribute("aria-expanded", this.element.open ? "true" : "false")
  }

  get #storageKey() {
    return `sidebar-group:${this.keyValue}`
  }
}
