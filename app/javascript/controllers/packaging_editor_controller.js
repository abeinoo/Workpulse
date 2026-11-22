import { Controller } from "@hotwired/stimulus"

// The packaging editor (inventory/product_packagings/edit): numbers each level
// (1 = innermost), labels what its "contains" field counts (base unit for
// level 1, the level below otherwise) and shows what one package equals in
// base units — "= 120 pcs" — as the user types. Caps the rows at max levels.
// The server (Inventory::Packaging::Configurator) validates and saves.
export default class extends Controller {
  static targets = ["addButton"]
  static values = { measure: String, max: Number }

  connect() { this.refresh() }

  refresh() {
    // Rows are added / removed by line-items in the same event; read after it.
    requestAnimationFrame(() => this.#render())
  }

  #render() {
    const rows = [ ...this.element.querySelectorAll("[data-packaging-level-row]") ].filter((row) => !row.hidden)
    let base = 1
    let below = this.measureValue
    rows.forEach((row, index) => {
      const unitSelect = row.querySelector("[data-package-unit-field]")
      const contains = parseFloat(row.querySelector("[data-contains-field]")?.value)
      row.querySelector("[data-level-position]").textContent = String(index + 1)
      row.querySelector("[data-contains-unit]").textContent = below
      base = Number.isFinite(contains) && contains > 0 ? base * contains : NaN
      row.querySelector("[data-level-base]").textContent = Number.isFinite(base) ? `= ${Math.round(base * 1000) / 1000} ${this.measureValue}` : "—"
      below = unitSelect?.selectedOptions[0]?.textContent?.trim() || "—"
    })
    if (this.hasAddButtonTarget) this.addButtonTarget.disabled = rows.length >= this.maxValue
  }
}
