import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["fields", "toggle"]

  connect() {
    this.update()
  }

  update() {
    const enabled = this.toggleTarget.checked
    this.fieldsTarget.hidden = !enabled

    if (enabled) {
      // After the browser paints the newly visible container, tell the map to resize
      requestAnimationFrame(() => {
        window.dispatchEvent(new CustomEvent("geo-fields:shown"))
      })
    }
  }
}
