import { Controller } from "@hotwired/stimulus"

// Handles the deposit form's Expected / Actual / Remaining calculation.
//
// data-controller="till-deposit"
// data-till-deposit-expected-value="5430.75"          (set per selected PM)
// data-till-deposit-amounts-value='{"1":5430.75}'     (JSON map pm_id → expected)
//
// Targets:
//   pmRadio       — payment method radio buttons (one or more)
//   expectedLabel — read-only display of expected amount
//   actualInput   — the amount the depositor types
//   remainingRow  — the whole remaining row (hidden when remaining == 0)
//   remainingLabel — read-only display of remaining amount
//   warningBox    — banner shown when remaining > 0
//   warningAmount — span inside warningBox showing the numeric shortfall
export default class extends Controller {
  static targets = [
    "pmRadio", "expectedLabel", "actualInput",
    "remainingRow", "remainingLabel", "warningBox", "warningAmount"
  ]
  static values = { expected: Number, amounts: Object }

  connect() {
    this.#updateDisplay()
  }

  // Called when a PM radio changes
  pmSelected(event) {
    const pmId = parseInt(event.target.value, 10)
    this.expectedValue = this.amountsValue[pmId] ?? 0
    this.#updateDisplay()
  }

  // Called on every keystroke in the actual-amount input
  recalculate() {
    this.#updateDisplay()
  }

  // ── private ─────────────────────────────────────────────────────────────────

  #updateDisplay() {
    const expected  = this.expectedValue || 0
    const actual    = parseFloat(this.actualInputTarget.value) || 0
    const remaining = Math.max(expected - actual, 0)

    if (this.hasExpectedLabelTarget) {
      this.expectedLabelTarget.textContent = this.#fmt(expected)
    }

    if (this.hasRemainingRowTarget) {
      this.remainingRowTarget.hidden = remaining === 0
    }
    if (this.hasRemainingLabelTarget) {
      this.remainingLabelTarget.textContent = this.#fmt(remaining)
    }
    if (this.hasWarningBoxTarget) {
      this.warningBoxTarget.hidden = remaining === 0
    }
    if (this.hasWarningAmountTarget) {
      this.warningAmountTarget.textContent = this.#fmt(remaining)
    }
  }

  #fmt(n) {
    return n.toLocaleString(undefined, { minimumFractionDigits: 2, maximumFractionDigits: 2 })
  }
}
