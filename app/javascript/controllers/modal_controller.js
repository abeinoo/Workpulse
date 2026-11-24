import { Controller } from "@hotwired/stimulus"

// Manages the global modal overlay.
// The overlay sits hidden in the layout. When <turbo-frame id="modal">
// receives content (via a data-turbo-frame="modal" link), a MutationObserver
// fires, which shows the backdrop. Clearing the frame hides it again.
//
// Placement: every modal is a bottom sheet by default (the layout's inline
// styles). Content that opts in with data-modal-placement="center" gets the
// overlay class "modal-overlay--centered" instead (centered dialog — see
// application.css); it is removed again as soon as other content is shown.
export default class extends Controller {
  static targets = ["frame"]

  connect() {
    this._observer = new MutationObserver(() => this.#sync())
    this._observer.observe(this.frameTarget, { childList: true, subtree: true })
    // Never let Turbo cache a page with a modal open: restoring that snapshot
    // (Back button) would show a stale, open form.
    this._beforeCache = () => this.close()
    document.addEventListener("turbo:before-cache", this._beforeCache)
    this.#sync()
  }

  disconnect() {
    this._observer?.disconnect()
    document.removeEventListener("turbo:before-cache", this._beforeCache)
  }

  // Called by backdrop click (data-action="click->modal#backdropClick")
  backdropClick(event) {
    if (event.target === event.currentTarget) this.close()
  }

  // Called by ESC keydown on window (data-action="keydown.esc@window->modal#close")
  close() {
    this.frameTarget.innerHTML = ""
    this.element.classList.remove("modal-overlay--centered")
    this.#setOpen(false)
  }

  // Prevent clicks inside the panel from bubbling to the backdrop
  stopPropagation(event) {
    event.stopPropagation()
  }

  #sync() {
    const open = this.frameTarget.innerHTML.trim().length > 0
    const centered = open && this.frameTarget.querySelector("[data-modal-placement='center']") !== null
    this.element.classList.toggle("modal-overlay--centered", centered)
    this.#setOpen(open)
  }

  // html.modal-open lets fixed page chrome that stacks above the overlay
  // (e.g. the PWA install banner) step aside so it can't cover modal actions.
  #setOpen(open) {
    this.element.style.display = open ? "flex" : "none"
    document.documentElement.classList.toggle("modal-open", open)
  }
}
