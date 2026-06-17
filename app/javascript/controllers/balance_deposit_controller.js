import { Controller } from "@hotwired/stimulus"

// Translates a signed amount into the correct txn_type + direction + magnitude
// before form submission, so the server-side CustodyTransactionCreator receives
// only positive magnitudes with explicit type/direction (its expected shape).
//
// Two modes — determined by which action is wired to the form's submit event:
//
//   prepare           (Deposit modal)
//     +amount  → txn_type=top_up,    direction=increase, magnitude=|amount|
//     -amount  → txn_type=adjustment, direction=decrease, magnitude=|amount|
//
//   prepareAdjustment (Adjustment modal)
//     +amount  → txn_type=adjustment, direction=increase, magnitude=|amount|
//     -amount  → txn_type=adjustment, direction=decrease, magnitude=|amount|
export default class extends Controller {
  static targets = ["signedAmount", "txnType", "direction", "magnitude"]

  prepare(event) {
    const raw = parseFloat(this.signedAmountTarget.value) || 0
    if (raw >= 0) {
      this.txnTypeTarget.value   = "top_up"
      this.directionTarget.value = "increase"
    } else {
      this.txnTypeTarget.value   = "adjustment"
      this.directionTarget.value = "decrease"
    }
    this.magnitudeTarget.value = Math.abs(raw)
  }

  prepareAdjustment(event) {
    const raw = parseFloat(this.signedAmountTarget.value) || 0
    this.txnTypeTarget.value   = "adjustment"
    this.directionTarget.value = raw >= 0 ? "increase" : "decrease"
    this.magnitudeTarget.value = Math.abs(raw)
  }
}
