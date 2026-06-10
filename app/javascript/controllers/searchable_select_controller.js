import { Controller } from "@hotwired/stimulus"

// Progressive enhancement: turns a native <select> into a searchable combobox.
//
// The underlying <select> remains the form's source of truth — and the no-JS
// fallback — so its value submits exactly as a plain select would. Choosing an
// option writes the value back to the <select> and fires a `change` event (so
// auto-submit / other listeners keep working).
export default class extends Controller {
  static targets = ["select"]

  connect() {
    if (!this.hasSelectTarget) return
    this._build()
    this._onOutside = (e) => { if (!this.element.contains(e.target)) this._close() }
    document.addEventListener("click", this._onOutside)
  }

  disconnect() {
    if (this._onOutside) document.removeEventListener("click", this._onOutside)
  }

  _build() {
    const select = this.selectTarget
    select.classList.add("visually-hidden")
    select.setAttribute("tabindex", "-1")
    select.setAttribute("aria-hidden", "true")

    this.combo = document.createElement("div")
    this.combo.className = "searchable-select"

    this.input = document.createElement("input")
    this.input.type = "text"
    this.input.className = "filter-bar__input searchable-select__input"
    this.input.setAttribute("role", "combobox")
    this.input.setAttribute("autocomplete", "off")
    this.input.placeholder = select.dataset.searchPlaceholder || ""
    this.input.addEventListener("focus", () => this._open())
    this.input.addEventListener("input", () => this._filter())
    this.input.addEventListener("keydown", (e) => this._onKeydown(e))

    this.menu = document.createElement("ul")
    this.menu.className = "searchable-select__menu"
    this.menu.setAttribute("role", "listbox")

    this.combo.appendChild(this.input)
    this.combo.appendChild(this.menu)
    select.insertAdjacentElement("afterend", this.combo)

    this._syncFromSelect()
  }

  _open() {
    this.combo.classList.add("is-open")
    this.input.select()
    this._render("")
  }

  _filter() {
    this.combo.classList.add("is-open")
    this._render(this.input.value)
  }

  _close() {
    this.combo.classList.remove("is-open")
    this._syncFromSelect()
  }

  _render(query) {
    const q = query.trim().toLowerCase()
    this.menu.innerHTML = ""
    Array.from(this.selectTarget.options).forEach((opt) => {
      if (q && !opt.text.toLowerCase().includes(q)) return
      const li = document.createElement("li")
      li.className = "searchable-select__option"
      li.textContent = opt.text
      li.setAttribute("role", "option")
      if (opt.value === this.selectTarget.value) li.setAttribute("aria-selected", "true")
      li.addEventListener("mousedown", (e) => {
        e.preventDefault()
        this._choose(opt.value)
      })
      this.menu.appendChild(li)
    })
  }

  _choose(value) {
    this.selectTarget.value = value
    this._syncFromSelect()
    this._close()
    this.selectTarget.dispatchEvent(new Event("change", { bubbles: true }))
  }

  _syncFromSelect() {
    const selected = this.selectTarget.options[this.selectTarget.selectedIndex]
    this.input.value = selected ? selected.text : ""
  }

  _onKeydown(event) {
    if (event.key === "Escape") {
      this._close()
      this.input.blur()
    }
  }
}
