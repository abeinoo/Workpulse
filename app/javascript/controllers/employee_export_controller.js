import { Controller } from "@hotwired/stimulus"

// Employee Data Export dialog (admin/users/_export_dialog): field search,
// select / deselect all (of the fields currently shown), the selected-fields
// counter and the Export button, enabled only with at least one field.
// Presentation only — the server validates every field again.
export default class extends Controller {
  static targets = ["search", "field", "group", "checkbox", "counter", "submit", "empty"]

  connect() {
    this.update()
  }

  filter() {
    const query = this.searchTarget.value.trim().toLowerCase()

    this.fieldTargets.forEach((field) => {
      field.hidden = query !== "" && !field.dataset.label.includes(query)
    })
    this.groupTargets.forEach((group) => {
      group.hidden = this.fieldTargets.every((field) => !group.contains(field) || field.hidden)
    })
    this.emptyTarget.hidden = this.fieldTargets.some((field) => !field.hidden)
  }

  selectAll() {
    this.visibleCheckboxes().forEach((checkbox) => { checkbox.checked = true })
    this.update()
  }

  deselectAll() {
    this.visibleCheckboxes().forEach((checkbox) => { checkbox.checked = false })
    this.update()
  }

  update() {
    const count = this.checkboxTargets.filter((checkbox) => checkbox.checked).length
    this.counterTarget.textContent = count
    this.submitTarget.disabled = count === 0
  }

  visibleCheckboxes() {
    return this.checkboxTargets.filter((checkbox) => !checkbox.closest("[hidden]"))
  }
}
