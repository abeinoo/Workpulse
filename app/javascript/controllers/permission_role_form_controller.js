import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["group", "groupToggle", "checkbox"]

  connect() {
    this.updateAllGroupToggles()
  }

  selectAll() {
    this.checkboxTargets.forEach(cb => { cb.checked = true })
    this.updateAllGroupToggles()
  }

  clearAll() {
    this.checkboxTargets.forEach(cb => { cb.checked = false })
    this.updateAllGroupToggles()
  }

  toggleGroup(event) {
    const toggle = event.currentTarget
    const group  = toggle.closest("[data-permission-role-form-target~='group']")
    group.querySelectorAll("[data-permission-role-form-target~='checkbox']")
         .forEach(cb => { cb.checked = toggle.checked })
  }

  updateGroupToggle(event) {
    const group = event.currentTarget
                       .closest("[data-permission-role-form-target~='group']")
    if (!group) return
    this._syncGroupToggle(group)
  }

  updateAllGroupToggles() {
    this.groupTargets.forEach(g => this._syncGroupToggle(g))
  }

  _syncGroupToggle(group) {
    const boxes  = [...group.querySelectorAll("[data-permission-role-form-target~='checkbox']")]
    const toggle = group.querySelector("[data-permission-role-form-target~='groupToggle']")
    if (!toggle) return
    const all  = boxes.every(b => b.checked)
    const some = boxes.some(b => b.checked)
    toggle.checked       = all
    toggle.indeterminate = !all && some
  }
}
