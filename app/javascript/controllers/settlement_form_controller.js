import { Controller } from "@hotwired/stimulus"

// Live guidance on the goods receipt settlement form. For Employee Custody —
// always the logged-in user's own custody — shows the custody balance after
// this settlement (balance − amount), which MAY be negative: custody is an
// accounting balance, not a spending limit. For every source, shows the
// receipt's remaining balance after this payment. Blocks submission only while
// the amount is zero/negative, above the receipt's remaining balance, or
// (Employee Custody) when the user has no active custody account.
// Purely a UX guard — Inventory::GoodsReceiptSettlementRecorder resolves the
// custody account from current_user and re-validates every rule server-side
// against the ledger.
//
// Money is formatted the same way as ApplicationHelper#format_currency
// (2 decimals, "," thousands; symbol after the number in Arabic, before it
// otherwise) using the symbol/locale the server passes in.
export default class extends Controller {
  static targets = ["kindRadio", "balanceAfter", "balanceAfterRow", "amount", "remainingAfter", "error", "submit"]
  static values = {
    remaining: Number,
    hasCustody: Boolean,
    balance: Number,
    symbol: String,
    locale: String,
    msgPositive: String,
    msgExceedsRemaining: String,
    msgNoCustody: String
  }

  connect() {
    this.update()
  }

  update() {
    const custody = this.selectedKind() === "employee_custody"
    const balance = custody && this.hasCustodyValue ? this.balanceValue : null
    const amount = parseFloat(this.amountTarget.value)
    const hasAmount = Number.isFinite(amount)

    this.amountTarget.max = this.remainingValue.toFixed(2)

    this.remainingAfterTarget.textContent =
      hasAmount && amount > 0 && amount <= this.remainingValue ? this.format(this.remainingValue - amount) : "—"

    // .form-group sets display:flex, which beats the UA [hidden] rule — toggle
    // the .hidden utility too (same fix as funding_source_controller.js).
    this.balanceAfterRowTarget.hidden = !custody
    this.balanceAfterRowTarget.classList.toggle("hidden", !custody)
    const after = balance !== null && hasAmount && amount > 0 ? balance - amount : null
    this.balanceAfterTarget.textContent = after === null ? "—" : this.format(after)
    this.balanceAfterTarget.classList.toggle("text-danger", after !== null && after < 0)

    let error = null
    if (custody && !this.hasCustodyValue) error = this.msgNoCustodyValue
    else if (!hasAmount || amount <= 0) error = this.msgPositiveValue
    else if (amount > this.remainingValue + 0.0001) error = this.msgExceedsRemainingValue

    this.errorTarget.textContent = error || ""
    this.errorTarget.hidden = !error
    this.submitTarget.disabled = !!error
  }

  selectedKind() {
    return this.kindRadioTargets.find((radio) => radio.checked)?.value
  }

  format(value) {
    const num = value.toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 })
    return this.localeValue === "ar" ? `${num} ${this.symbolValue}` : `${this.symbolValue} ${num}`
  }
}
