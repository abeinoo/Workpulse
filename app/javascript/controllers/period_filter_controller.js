import { Controller } from "@hotwired/stimulus"

// Shows/hides the Expense Details report's period sub-fields based on the
// selected "نوع الفترة" (period_type): the anchor month/year selects for
// single_month and the last-N-months presets, or the from/to month+year
// selects for a custom range. Pure display toggling — never submits the
// form itself, the page keeps its explicit "تطبيق الفلاتر" submit button.
//
// data-controller="period-filter"
// data-period-filter-target="typeSelect|anchorFields|customFields"
// data-action="change->period-filter#toggle"
export default class extends Controller {
  static targets = ["typeSelect", "anchorFields", "customFields"]

  connect() {
    this.toggle()
  }

  toggle() {
    const isCustom = this.typeSelectTarget.value === "custom"
    this.anchorFieldsTargets.forEach(el => { el.hidden = isCustom })
    this.customFieldsTargets.forEach(el => { el.hidden = !isCustom })
  }
}
