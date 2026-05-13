import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  connect() {
    this.toggleFields()
  }

  toggleFields() {
    const select = this.element.querySelector("select[name$='[shift_type]']")
    if (!select) return
    const isFixed = select.value === "fixed_time"
    this.element.querySelectorAll(".js-fixed-fields").forEach(el => { el.hidden = !isFixed })
    this.element.querySelectorAll(".js-hour-fields").forEach(el => { el.hidden = isFixed })
  }
}
