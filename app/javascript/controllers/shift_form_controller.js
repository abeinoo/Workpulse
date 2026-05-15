import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["fixedFields", "hourFields", "fixedRuleHint", "hourRuleHint"]

  connect() {
    this.toggleFields()
  }

  toggleFields() {
    const select = this.element.querySelector("select[name$='[shift_type]']")
    if (!select) return
    const isFixed = select.value === "fixed_time"
    this.fixedFieldsTargets.forEach(el => this._setVisible(el, isFixed))
    this.hourFieldsTargets.forEach(el => this._setVisible(el, !isFixed))
    this.fixedRuleHintTargets.forEach(el => this._setVisible(el, isFixed))
    this.hourRuleHintTargets.forEach(el => this._setVisible(el, !isFixed))
    this._syncPenaltyRuleTypes(isFixed)
  }

  // Called by penalty_rules_controller after a new row is inserted so the
  // newly-added row reflects the current shift type immediately.
  syncNewRow(row) {
    const select = this.element.querySelector("select[name$='[shift_type]']")
    const isFixed = !select || select.value === "fixed_time"
    this._applyTypeToRow(row, isFixed)
  }

  _setVisible(el, visible) {
    if (visible) {
      el.hidden = false
      el.querySelectorAll("input, select, textarea").forEach(inp => { inp.disabled = false })
      el.classList.add("shift-field--entering")
      setTimeout(() => el.classList.remove("shift-field--entering"), 250)
    } else {
      el.hidden = true
      el.classList.remove("shift-field--entering")
      el.querySelectorAll("input, select, textarea").forEach(inp => { inp.disabled = true })
    }
  }

  _syncPenaltyRuleTypes(isFixed) {
    this.element.querySelectorAll("[data-rule-row]").forEach(row => {
      this._applyTypeToRow(row, isFixed)
    })
  }

  _applyTypeToRow(row, isFixed) {
    row.querySelectorAll(".js-rule-type-wrapper").forEach(el => { el.hidden = !isFixed })
    row.querySelectorAll(".js-shortfall-label").forEach(el => { el.hidden = isFixed })
    if (!isFixed) {
      // Force rule_type to early_leave; PenaltyCalculator applies all rules to
      // hour shortfall regardless of rule_type, but early_leave is the canonical value.
      row.querySelectorAll(".js-rule-type-select").forEach(sel => { sel.value = "early_leave" })
    }
  }
}
