import { Controller } from "@hotwired/stimulus"

// "Add advance payment" form: once an employee custody account is chosen,
// shows its current balance, the advance amount and the balance after
// payment. A negative result is shown clearly but NEVER blocks submission —
// custody is an accounting balance and may go negative. Display only; the
// server posts the real ledger entry at confirmation.
export default class extends Controller {
  static targets = ["account", "amount", "preview", "current", "advance", "after", "negativeNote"]
  static values = { currencyPrefix: String, currencySuffix: String }

  connect() {
    this.update()
  }

  update() {
    if (!this.hasAccountTarget || !this.hasPreviewTarget) return

    const option = this.accountTarget.selectedOptions[0]
    if (!option || !option.value) {
      this.previewTarget.hidden = true
      return
    }

    const balance = parseFloat(option.dataset.balance) || 0
    const amount  = this.hasAmountTarget ? (parseFloat(this.amountTarget.value) || 0) : 0
    const after   = balance - amount

    this.previewTarget.hidden = false
    this.currentTarget.textContent = this._format(balance)
    this.advanceTarget.textContent = this._format(amount)
    this.afterTarget.textContent   = this._format(after)
    this.afterTarget.style.color   = after < 0 ? "var(--danger)" : ""
    this.negativeNoteTarget.hidden = !(after < 0)
  }

  _format(value) {
    const num = Math.abs(value).toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 })
    // Minus outside the currency wrapper, isolated so it stays put in RTL.
    const sign = value < 0 ? "−" : ""
    return `⁦${sign}${this.currencyPrefixValue}${num}${this.currencySuffixValue}⁩`
  }
}
