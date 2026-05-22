import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["type", "alreadyPaidSection", "alreadyPaidCheckbox", "paidDetails"]

  // Safety net: re-run on connect in case of Turbo cache restores.
  connect() {
    this.onChange()
  }

  // Fires when the type <select> changes.
  onChange() {
    const isCashIncentive = this.typeTarget.value === "cash_incentive"

    this.alreadyPaidSectionTarget.style.display = isCashIncentive ? "" : "none"

    // Reset nested state when switching away from cash_incentive.
    if (!isCashIncentive) {
      this.alreadyPaidCheckboxTarget.checked = false
      this.paidDetailsTarget.style.display = "none"
    }
  }

  // Fires when the already_paid checkbox is toggled.
  togglePaidDetails() {
    this.paidDetailsTarget.style.display = this.alreadyPaidCheckboxTarget.checked ? "" : "none"
  }
}
