import { Controller } from "@hotwired/stimulus"

// Lazy-loads child product rows for a parent product row in the products index.
//
// Usage on the parent <tr>:
//   data-controller="product-family"
//   data-product-family-url-value="/inventory/products/123/children"
//   data-product-id="123"
//
// The trigger button inside must have:
//   data-action="click->product-family#toggle"
//   data-product-family-target="trigger"
export default class extends Controller {
  static targets = [ "trigger" ]
  static values  = {
    url:    String,
    open:   { type: Boolean, default: false },
    loaded: { type: Boolean, default: false }
  }

  toggle() {
    if (!this.loadedValue) {
      this.#fetch()
    } else {
      this.#setOpen(!this.openValue)
    }
  }

  async #fetch() {
    this.triggerTargets.forEach(el => el.setAttribute("aria-busy", "true"))
    try {
      const resp = await fetch(this.urlValue, {
        headers: {
          Accept: "text/html",
          "X-Requested-With": "XMLHttpRequest"
        }
      })
      if (!resp.ok) return
      const html = await resp.text()
      this.element.insertAdjacentHTML("afterend", html)
      this.loadedValue = true
      this.#setOpen(true)
    } finally {
      this.triggerTargets.forEach(el => el.removeAttribute("aria-busy"))
    }
  }

  #setOpen(open) {
    this.openValue = open
    const parentId = this.element.dataset.productId
    document
      .querySelectorAll(`[data-parent-id="${parentId}"]`)
      .forEach(row => { row.hidden = !open })
    this.triggerTargets.forEach(el => {
      el.setAttribute("aria-expanded", open ? "true" : "false")
      el.textContent = open ? "▼" : "▶"
    })
  }
}
