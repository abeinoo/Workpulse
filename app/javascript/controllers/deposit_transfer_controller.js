import { Controller } from "@hotwired/stimulus"

// Transfer Deposit Responsibility modal. Selecting an employee changes
// nothing — it only enables "Confirm Transfer" and names the recipient in the
// inline summary and in the form's Turbo confirm dialog, so the transfer is
// submitted only after the user explicitly confirms that exact name.
export default class extends Controller {
  static targets = ["select", "submit", "summary"]
  static values  = { confirmTemplate: String }

  connect() {
    this.update()
  }

  update() {
    const option = this.selectTarget.selectedOptions[0]
    const name   = option && option.value ? option.textContent.trim() : null

    this.submitTarget.disabled = !name
    this.summaryTarget.hidden  = !name

    if (name) {
      const message = this.confirmTemplateValue.replace("%{name}", name)
      this.summaryTarget.textContent = message
      this.element.setAttribute("data-turbo-confirm", message)
    } else {
      this.summaryTarget.textContent = ""
      this.element.removeAttribute("data-turbo-confirm")
    }
  }
}
