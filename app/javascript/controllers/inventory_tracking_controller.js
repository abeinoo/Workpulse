import { Controller } from "@hotwired/stimulus"

// Shows/hides the notification fields when "Track Inventory" is toggled.
// Prevents sending notification settings for untracked products.
export default class extends Controller {
  static targets = ["notificationFields"]

  toggle(event) {
    const show = event.target.checked
    this.notificationFieldsTargets.forEach(el => {
      el.hidden = !show
      el.querySelectorAll("input").forEach(input => { input.disabled = !show })
    })
  }
}
