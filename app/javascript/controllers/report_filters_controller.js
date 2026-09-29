import { Controller } from "@hotwired/stimulus"

// Auto-applying report filters. The form stays a plain GET — the server does
// all filtering. It targets a Turbo Frame around the results and advances the
// URL (data-turbo-frame + data-turbo-action="advance"), so only the results
// update, the query string always holds the filters (refresh / back-forward /
// share), and nothing is filtered on the client.
//
//   <form data-controller="report-filters"
//         data-action="change->report-filters#changed" …>
//
// Targets: period (select), custom (wrappers shown only for "custom"),
// from / to (date inputs), error (invalid-range message).
export default class extends Controller {
  static targets = ["period", "custom", "from", "to", "error"]
  static values = { delay: { type: Number, default: 200 } }

  connect() {
    this.#toggleCustom()
    this.lastQuery = this.#query()
  }

  disconnect() {
    clearTimeout(this.timer)
  }

  changed(event) {
    const target = event.target
    if (this.hasPeriodTarget && target === this.periodTarget) {
      this.#toggleCustom()
      if (this.#isCustom()) return this.#submitCustomWhenValid()
    } else if (this.#isDateInput(target)) {
      return this.#submitCustomWhenValid()
    }
    this.#schedule()
  }

  // A custom range is only applied once both dates are filled and ordered.
  #submitCustomWhenValid() {
    const from = this.fromTarget.value
    const to = this.toTarget.value
    if (!from || !to) return this.#showError(false)
    if (from > to) return this.#showError(true)

    this.#showError(false)
    this.#schedule()
  }

  // Several controls can fire in quick succession (e.g. the searchable select
  // dispatching change); collapse them into one request, and never re-submit
  // an unchanged query.
  #schedule() {
    clearTimeout(this.timer)
    this.timer = setTimeout(() => this.#submit(), this.delayValue)
  }

  #submit() {
    const query = this.#query()
    if (query === this.lastQuery) return

    this.lastQuery = query
    // Leave blank selects ("all branches"…) out of the URL: Turbo reads the
    // form data synchronously on submit, so disable them just for that tick.
    const blanks = [...this.element.elements].filter((el) => el.name && !el.disabled && el.value === "")
    blanks.forEach((el) => { el.disabled = true })
    this.element.requestSubmit()
    setTimeout(() => blanks.forEach((el) => { el.disabled = false }))
  }

  #query() {
    return new URLSearchParams(new FormData(this.element)).toString()
  }

  #isCustom() {
    return this.hasPeriodTarget && this.periodTarget.value === "custom"
  }

  #isDateInput(target) {
    return (this.hasFromTarget && target === this.fromTarget) || (this.hasToTarget && target === this.toTarget)
  }

  // Preset periods hide AND disable the date inputs so they are not sent.
  #toggleCustom() {
    const on = this.#isCustom()
    this.customTargets.forEach((el) => { el.hidden = !on })
    if (this.hasFromTarget) this.fromTarget.disabled = !on
    if (this.hasToTarget) this.toTarget.disabled = !on
    if (!on) this.#showError(false)
  }

  #showError(on) {
    if (this.hasErrorTarget) this.errorTarget.hidden = !on
  }
}
