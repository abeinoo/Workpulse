import { Controller } from "@hotwired/stimulus"

// The packaging editor (inventory/product_packagings/edit). Everything follows
// the BASE UNIT chosen on the form (the product's Measure — ml, g, pieces, …;
// never assumed to be a piece):
//   * numbers each level (1 = innermost);
//   * labels what its "contains" field counts — the base unit for level 1,
//     the level below for the others;
//   * shows what one package equals in base units ("= 2500 ml");
//   * lists the whole conversion chain, outermost first
//     ("1 carton = 10 bottles = 2500 ml", "1 bottle = 250 ml");
//   * caps the rows at the maximum number of levels.
// Display only: the server (Inventory::Packaging::Configurator) validates and saves.
export default class extends Controller {
  static targets = ["addButton", "baseUnit", "chain"]
  static values = { max: Number }

  connect() { this.refresh() }

  refresh() {
    // Rows are added / removed by line-items in the same event; read after it.
    requestAnimationFrame(() => this.#render())
  }

  get #measure() {
    return this.hasBaseUnitTarget ? (this.baseUnitTarget.selectedOptions[0]?.dataset.short || "") : ""
  }

  #render() {
    const measure = this.#measure
    const rows = [ ...this.element.querySelectorAll("[data-packaging-level-row]") ].filter((row) => !row.hidden)
    const levels = []
    let base = 1
    let below = measure
    rows.forEach((row, index) => {
      const option = row.querySelector("[data-package-unit-field]")?.selectedOptions[0]
      const contains = parseFloat(row.querySelector("[data-contains-field]")?.value)
      row.querySelector("[data-level-position]").textContent = String(index + 1)
      row.querySelector("[data-contains-unit]").textContent = below
      base = Number.isFinite(contains) && contains > 0 ? base * contains : NaN
      row.querySelector("[data-level-base]").textContent = Number.isFinite(base) ? `= ${round(base)} ${measure}` : "—"
      levels.push({ option, contains, base, below: index === 0 ? null : levels[index - 1].option })
      below = option?.value ? option.textContent.trim() : "—"
    })
    if (this.hasAddButtonTarget) this.addButtonTarget.disabled = rows.length >= this.maxValue
    this.#renderChain(levels, measure)
  }

  // Outermost first: "1 carton = 10 bottles = 2500 ml".
  #renderChain(levels, measure) {
    if (!this.hasChainTarget) return
    const list = this.chainTarget
    list.innerHTML = ""
    const complete = levels.filter((l) => l.option?.value && Number.isFinite(l.contains) && l.contains > 0 && Number.isFinite(l.base))
    if (complete.length === 0 || complete.length !== levels.length) {
      const item = document.createElement("li")
      item.className = "td-secondary"
      item.textContent = list.dataset.empty || ""
      list.appendChild(item)
      return
    }
    complete.slice().reverse().forEach((level) => {
      const parts = [ count(level.option, 1) ]
      if (level.below) parts.push(count(level.below, level.contains))
      parts.push(`${round(level.base)} ${measure}`)
      const item = document.createElement("li")
      item.textContent = parts.join(" = ")
      list.appendChild(item)
    })
  }
}

function round(value) { return Math.round(value * 1000) / 1000 }

// "1 carton" / "10 bottles" from the option's translated forms.
function count(option, amount) {
  const form = amount > 0 && amount <= 1 ? option.dataset.one : option.dataset.other
  return (form || `%{count} ${option.textContent.trim()}`).replace("%{count}", String(round(amount)))
}
