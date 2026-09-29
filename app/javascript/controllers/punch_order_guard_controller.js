import { Controller } from "@hotwired/stimulus"

// Live feedback for check-out punch corrections: the selected check-out must
// be strictly after the check-in. Server-side validation (EmployeeRequest,
// Requests::Approver, Requests::PunchCorrectionApplier) is authoritative —
// this only surfaces the message early and blocks an obviously invalid submit.
// The submit button is never disabled: pickers don't always emit DOM events on
// programmatic changes, so the check is re-run on submit instead.
//
// All values are business-timezone local datetimes "YYYY-MM-DDTHH:MM", so a
// plain string comparison compares the FULL datetime (an overnight check-out
// on the next day is later than the check-in).
//
// Values:
//   checkIn   fixed check-in (reviewer form)
//   checkIns  { "YYYY-MM-DD" work date → check-in } (request form)
// Targets (all optional except error):
//   datetime        one "Y-m-d\TH:i" input (reviewer form)
//   date + time     separate punch date / "H:i" inputs (request form)
//   workDate        work-date input, looked up in checkIns
//   correctionType  correction-type select; guard applies to check-out types only
//   requestType     request-type select; guard applies to punch corrections only
export default class extends Controller {
  static targets = [ "datetime", "date", "time", "workDate", "correctionType", "requestType", "error" ]
  static values  = { checkIn: String, checkIns: Object }

  static CHECK_OUT_TYPES = [ "missing_check_out", "wrong_check_out_time" ]

  connect() {
    this.check()
  }

  check() {
    this.errorTarget.hidden = !this.#invalid()
  }

  validate(event) {
    this.check()
    if (this.errorTarget.hidden) return

    event.preventDefault()
    event.stopImmediatePropagation()
    this.errorTarget.scrollIntoView({ block: "center" })
  }

  #invalid() {
    if (this.hasRequestTypeTarget && this.requestTypeTarget.value !== "punch_correction") return false
    if (this.hasCorrectionTypeTarget &&
        !this.constructor.CHECK_OUT_TYPES.includes(this.correctionTypeTarget.value)) return false

    const checkIn  = this.#checkIn()
    const checkOut = this.#checkOut()
    if (!checkIn || !checkOut) return false

    return checkOut <= checkIn
  }

  #checkIn() {
    if (this.checkInValue) return this.checkInValue
    if (this.hasWorkDateTarget) return this.checkInsValue[this.workDateTarget.value]
  }

  #checkOut() {
    if (this.hasDatetimeTarget) {
      const value = this.datetimeTarget.value.trim().replace(" ", "T")
      return /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}/.test(value) ? value.slice(0, 16) : null
    }
    if (!this.hasDateTarget || !this.hasTimeTarget) return null

    const date = this.dateTarget.value || (this.hasWorkDateTarget ? this.workDateTarget.value : "")
    const time = this.timeTarget.value.match(/^(\d{1,2}):(\d{2})/)
    if (!/^\d{4}-\d{2}-\d{2}$/.test(date) || !time) return null

    return `${date}T${time[1].padStart(2, "0")}:${time[2]}`
  }
}
