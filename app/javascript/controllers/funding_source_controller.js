import { Controller } from "@hotwired/stimulus"

// Toggles the "Employee Custody" balance panel on a goods receipt form based
// on the selected funding source kind. The account is always the current
// user's own — there is no employee selector — so the panel just needs to
// show or hide; the balance itself is rendered server-side.
export default class extends Controller {
  static targets = ["kindRadio", "panel"]

  connect() {
    this.toggle()
  }

  toggle() {
    const checked = this.kindRadioTargets.find((radio) => radio.checked)
    const isEmployeeCustody = checked?.value === "employee_custody"
    // The panel is a .form-group, which sets its own `display: flex` at equal
    // CSS specificity to the browser's default `[hidden] { display: none }` —
    // the app rule wins (author stylesheet beats UA stylesheet), so the plain
    // `hidden` property alone doesn't visually hide it. Toggle the `.hidden`
    // utility class (`display: none !important`) instead.
    this.panelTarget.classList.toggle("hidden", !isEmployeeCustody)
    this.panelTarget.hidden = !isEmployeeCustody
  }
}
