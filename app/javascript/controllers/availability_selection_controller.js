import { Controller } from "@hotwired/stimulus"

// Add products to a warehouse (Products tab → Add products).
//
// Checkbox selection over the current page: the header box toggles every
// enabled row box (rows already configured here are disabled by the server),
// with an indeterminate state for a partial selection. The submit button
// shows the count and stays disabled while nothing is selected. Selection
// always starts from what the server rendered (a re-render after a refused
// batch keeps the user's ticks); the server validates every row again.
export default class extends Controller {
  static targets = ["master", "row", "submit", "count"]

  connect() {
    this.sync()
  }

  toggleAll() {
    const checked = this.masterTarget.checked
    this.enabledRows.forEach((box) => { box.checked = checked })
    this.sync()
  }

  sync() {
    const enabled = this.enabledRows
    const selected = enabled.filter((box) => box.checked).length
    if (this.hasMasterTarget) {
      this.masterTarget.checked = enabled.length > 0 && selected === enabled.length
      this.masterTarget.indeterminate = selected > 0 && selected < enabled.length
      this.masterTarget.disabled = enabled.length === 0
    }
    if (this.hasCountTarget) this.countTarget.textContent = selected
    if (this.hasSubmitTarget) this.submitTarget.disabled = selected === 0
  }

  get enabledRows() {
    return this.rowTargets.filter((box) => !box.disabled)
  }
}
