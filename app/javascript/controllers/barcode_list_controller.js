import { Controller } from "@hotwired/stimulus"

// Manages the barcode section on the product form.
// Works alongside the line-items controller (add/remove rows) and adds:
//   • setPrimary  — enforces single-primary checkbox behaviour per product
//   • generate    — fetches the next internal code and fills a NEW form row
//
// Nothing is written before the product is saved (New and Edit alike): the
// generated barcode is an ordinary unsaved row, so removing it (×) before
// saving leaves no record, and Save inserts it with the rest of the product.
export default class extends Controller {
  static values = { generateUrl: String }

  setPrimary(event) {
    if (!event.target.checked) return
    // Demote all other primary checkboxes in this product's barcode section.
    this.element.querySelectorAll("input[data-primary-cb]").forEach(cb => {
      if (cb !== event.target) cb.checked = false
    })
  }

  async generate(event) {
    const btn = event.currentTarget
    const originalHtml = btn.innerHTML
    btn.disabled = true

    try {
      const res = await fetch(this.generateUrlValue, { headers: { Accept: "application/json" } })
      if (!res.ok) throw new Error(`HTTP ${res.status}`)
      const code = (await res.json()).code

      // Clone the template row
      const template = this.element.querySelector('[data-line-items-target="template"]')
      if (!template) return

      const idx  = Date.now()
      const html = template.innerHTML.replace(/NEW_INDEX/g, idx)
      const rows = this.element.querySelector('[data-line-items-target="rows"]')
      rows.insertAdjacentHTML("beforeend", html)
      const newRow = rows.lastElementChild

      // Pre-fill barcode value
      const input = newRow.querySelector('input[type="text"], input:not([type])')
      if (input) { input.value = code; input.dispatchEvent(new Event("input", { bubbles: true })) }

      // Set barcode type to "internal"
      const typeSelect = newRow.querySelector("select")
      if (typeSelect) typeSelect.value = "internal"

      // Primary when no visible row is primary yet.
      const noPrimaryYet = !this.element.querySelector("[data-line-row]:not([hidden]) input[data-primary-cb]:checked")
      if (noPrimaryYet) {
        const cb = newRow.querySelector("input[data-primary-cb]")
        if (cb) {
          cb.checked = true
          cb.dispatchEvent(new Event("change", { bubbles: true })) // triggers setPrimary
        }
      }

      // Hide empty state
      const empty = this.element.querySelector('[data-line-items-target="emptyState"]')
      if (empty) empty.hidden = true

      newRow.scrollIntoView({ behavior: "smooth", block: "nearest" })

    } catch (err) {
      console.error("[BarcodeList] generate:", err)
    } finally {
      btn.disabled  = false
      btn.innerHTML = originalHtml
    }
  }
}
