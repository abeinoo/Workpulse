import { Controller } from "@hotwired/stimulus"

// "Add advance payment" form. Every advance funds the Purchase Request's
// responsible employee's custody: the form always shows their balance after
// the amount (recipientBalance + amount). For an employee custody transfer,
// once the source account is chosen it also shows that account's current
// balance, the amount and its balance after. A negative source balance is shown
// clearly but NEVER blocks submission — custody is an accounting balance and
// may go negative. Display only; the server enforces every rule and posts the
// real ledger entries at confirmation.
export default class extends Controller {
  static targets = ["account", "amount", "preview", "current", "advance", "after", "negativeNote", "recipientAfter"]
  static values = { currencyPrefix: String, currencySuffix: String, recipientBalance: Number }

  connect() {
    this.update()
  }

  update() {
    const amount = this.hasAmountTarget ? (parseFloat(this.amountTarget.value) || 0) : 0
    if (this.hasRecipientAfterTarget) {
      this.recipientAfterTarget.textContent = this._format(this.recipientBalanceValue + amount)
    }
    if (!this.hasAccountTarget || !this.hasPreviewTarget) return

    const option = this.accountTarget.selectedOptions[0]
    if (!option || !option.value) {
      this.previewTarget.hidden = true
      return
    }

    const balance = parseFloat(option.dataset.balance) || 0
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
