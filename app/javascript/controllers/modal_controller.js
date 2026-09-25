import { Controller } from "@hotwired/stimulus"

// Manages the global modal overlay.
// The overlay sits hidden in the layout. When <turbo-frame id="modal">
// receives content (via a data-turbo-frame="modal" link), a MutationObserver
// fires, which shows the backdrop. Clearing the frame hides it again.
export default class extends Controller {
  static targets = ["frame"]

  connect() {
    this._observer = new MutationObserver(() => this.#sync())
    this._observer.observe(this.frameTarget, { childList: true, subtree: true })
    this.#sync()
  }

  disconnect() {
    this._observer?.disconnect()
  }

  // Called by backdrop click (data-action="click->modal#backdropClick")
  backdropClick(event) {
    if (event.target === event.currentTarget) this.close()
  }

  // Called by ESC keydown on window (data-action="keydown.esc@window->modal#close")
  close() {
    this.frameTarget.innerHTML = ""
    this.#setOpen(false)
  }

  // Prevent clicks inside the panel from bubbling to the backdrop
  stopPropagation(event) {
    event.stopPropagation()
  }

  #sync() {
    this.#setOpen(this.frameTarget.innerHTML.trim().length > 0)
  }

  // html.modal-open lets fixed page chrome that stacks above the overlay
  // (e.g. the PWA install banner) step aside so it can't cover modal actions.
  #setOpen(open) {
    this.element.style.display = open ? "flex" : "none"
    document.documentElement.classList.toggle("modal-open", open)
  }
}
