import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["sidebar", "overlay"]

  connect() {
    // Close the drawer automatically when Turbo navigates to a new page
    this._onVisit = () => this.close()
    document.addEventListener("turbo:visit", this._onVisit)
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
}
