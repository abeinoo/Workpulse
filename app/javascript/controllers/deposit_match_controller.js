import { Controller } from "@hotwired/stimulus"

// Multi-select "which bank transactions make up this deposit" checkbox list.
// Sums the checked transactions' amounts against the deposit's target amount
// and only enables "Confirm Match" once they're exactly equal.
//
// data-controller="deposit-match"
// data-deposit-match-target-value="11700.00"
//
// Targets:
//   checkbox      — one per candidate transaction (data-amount on each input)
//   selectedTotal — "11,700 / 11,700" display
//   confirmButton — submit button, disabled unless selected total == target
export default class extends Controller {
  static targets = ["checkbox", "selectedTotal", "confirmButton"]
  static values = { target: Number }

  connect() {
    this.#update()
  }

  toggle() {
    this.#update()
  }

  #update() {
    const selected = this.checkboxTargets.filter((c) => c.checked)
    const total = selected.reduce((sum, c) => sum + (parseFloat(c.dataset.amount) || 0), 0)
    const target = this.targetValue || 0
    const matches = selected.length > 0 && Math.abs(total - target) < 0.001

    if (this.hasSelectedTotalTarget) {
      this.selectedTotalTarget.textContent = `${this.#fmt(total)} / ${this.#fmt(target)}`
      this.selectedTotalTarget.classList.toggle("deposit-match__total--ok", matches)
    }

    if (this.hasConfirmButtonTarget) {
      this.confirmButtonTarget.disabled = !matches
    }
  }

  #fmt(n) {
    return n.toLocaleString(undefined, { minimumFractionDigits: 2, maximumFractionDigits: 2 })
  }
}
