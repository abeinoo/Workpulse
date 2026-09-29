import { Controller } from "@hotwired/stimulus"

// Full-screen viewer for an ID card photo on the employee data request review
// page: open/close a native <dialog>, toggle fit ↔ actual-size zoom (the stage
// scrolls when zoomed), and rotate in 90° steps for sideways phone photos.
export default class extends Controller {
  static targets = ["dialog", "stage", "image", "zoomButton"]

  connect() {
    this.rotation = 0
    this.zoomed = false
  }

  open() {
    this.dialogTarget.showModal()
  }

  close() {
    this.dialogTarget.close()
  }

  backdrop(event) {
    if (event.target === this.dialogTarget) this.close()
  }

  zoom() {
    this.zoomed = !this.zoomed
    this.stageTarget.classList.toggle("is-zoomed", this.zoomed)
    const button = this.zoomButtonTarget
    button.textContent = this.zoomed ? button.dataset.zoomOut : button.dataset.zoomIn
  }

  rotate() {
    this.rotation = (this.rotation + 90) % 360
    this.imageTarget.style.transform = `rotate(${this.rotation}deg)`
  }
}
