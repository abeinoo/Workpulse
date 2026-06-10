import { Controller } from "@hotwired/stimulus"

// Drives row selection and the bulk Approve/Reject actions on the Adjustments index.
//
// Responsibilities:
//   1. Show / hide the sticky bulk-action bar as row checkboxes are toggled.
//   2. Keep the "X selected" badge current and the select-all master checkbox
//      (checked / indeterminate) in sync over the selectable (pending) rows.
//   3. On Approve/Reject, inject one hidden adjustment_ids[] input per selected
//      row into the matching form and submit it (after an optional confirm).
export default class extends Controller {
  static targets = [
    "actionBar",
    "countBadge",
    "approveForm",
    "rejectForm",
    "approveIds",
    "rejectIds",
  ]

  static values = {
    approveConfirm: String,
    rejectConfirm: String,
  }

  connect() {
    this._sync()
  }

  get allBoxes() {
    return Array.from(this.element.querySelectorAll(".bulk-check-row"))
  }

  get checkedBoxes() {
    return this.allBoxes.filter((b) => b.checked)
  }

  toggleAll(event) {
    const checked = event.target.checked
    this.allBoxes.forEach((b) => { b.checked = checked })
    this._sync()
  }

  rowChanged() {
    const master = this.element.querySelector(".bulk-check-all")
    if (master) {
      const all = this.allBoxes
      const checked = this.checkedBoxes
      master.checked = all.length > 0 && checked.length === all.length
      master.indeterminate = checked.length > 0 && checked.length < all.length
    }
    this._sync()
  }

  submitApprove(event) {
    this._submit(event, this.approveFormTarget, this.approveIdsTarget, this.approveConfirmValue)
  }

  submitReject(event) {
    this._submit(event, this.rejectFormTarget, this.rejectIdsTarget, this.rejectConfirmValue)
  }

  _submit(event, form, container, confirmTemplate) {
    event.preventDefault()
    const boxes = this.checkedBoxes
    if (boxes.length === 0) return

    if (confirmTemplate) {
      const message = confirmTemplate.replace("%{count}", boxes.length)
      if (!window.confirm(message)) return
    }

    container.innerHTML = boxes
      .map((b) => `<input type="hidden" name="adjustment_ids[]" value="${b.value}">`)
      .join("")

    if (form.requestSubmit) {
      form.requestSubmit()
    } else {
      form.submit()
    }
  }

  _sync() {
    const count = this.checkedBoxes.length
    const hasAny = count > 0
    if (this.hasActionBarTarget) {
      this.actionBarTarget.style.display = hasAny ? "" : "none"
    }
    if (this.hasCountBadgeTarget) {
      this.countBadgeTarget.textContent = count
    }
  }
}
