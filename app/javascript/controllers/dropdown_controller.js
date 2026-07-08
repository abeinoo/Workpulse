import { Controller } from "@hotwired/stimulus"

// Small "⋮" action menu: toggles a floating panel open/closed, closes on an
// outside click or Escape. Usage:
//   <div data-controller="dropdown">
//     <button data-action="click->dropdown#toggle" data-dropdown-target="button">⋮</button>
//     <div data-dropdown-target="menu" hidden>...items...</div>
//   </div>
export default class extends Controller {
  static targets = ["menu"]

  toggle(event) {
    event.stopPropagation()
    this.menuTarget.hidden ? this.open() : this.close()
  }

  open() {
    this.menuTarget.hidden = false
    this._onOutside = (e) => { if (!this.element.contains(e.target)) this.close() }
    this._onEscape  = (e) => { if (e.key === "Escape") this.close() }
    document.addEventListener("click", this._onOutside)
    document.addEventListener("keydown", this._onEscape)
  }

  close() {
    this.menuTarget.hidden = true
    if (this._onOutside) document.removeEventListener("click", this._onOutside)
    if (this._onEscape)  document.removeEventListener("keydown", this._onEscape)
  }

  disconnect() {
    this.close()
  }
}
