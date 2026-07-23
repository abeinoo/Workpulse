import { Controller } from "@hotwired/stimulus"

// Live duplicate-prevention feedback for the towel transfer line-items table:
// a towel type already chosen on one row is greyed out (disabled) in every
// other row's select. This is a UX nicety only — the hard guarantee is
// TowelTransferItem's uniqueness validation plus the DB unique index on
// [towel_transfer_id, towel_type_id].
export default class extends Controller {
  static targets = ["typeSelect"]

  connect() {
    this.refresh()
  }

  refresh() {
    const visibleSelects = this.typeSelectTargets.filter((select) => !select.closest("[data-line-row]")?.hidden)
    const chosen = visibleSelects.map((select) => select.value).filter((value) => value !== "")

    visibleSelects.forEach((select) => {
      Array.from(select.options).forEach((option) => {
        if (option.value === "") return
        option.disabled = option.value !== select.value && chosen.includes(option.value)
      })
    })
  }
}
