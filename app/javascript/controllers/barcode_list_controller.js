import { Controller } from "@hotwired/stimulus"

// Manages the barcode section on the product form.
// Works alongside the line-items controller (add/remove rows) and adds:
//   • setPrimary      — enforces single-primary checkbox behaviour
//   • generate        — creates/fills an internal barcode row
//
// Two generation modes (selected automatically by which value is present):
//   • generateSaveUrl  (POST) — edit page: atomically creates the barcode
//     on the server, then adds a pre-filled row with the saved id so the
//     subsequent form submit does an UPDATE, not a duplicate INSERT.
//   • generateUrl      (GET)  — new-product page: fetches the next code
//     and fills a form row; the barcode is saved when the product is saved.
export default class extends Controller {
  static targets = ["variantSelect"]
  static values  = { generateUrl: String, generateSaveUrl: String }

  setPrimary(event) {
    if (!event.target.checked) return
    // When variants are in use, enforce single-primary per variant group, not globally.
    const row = event.target.closest("[data-line-row]")
    const variantSelect = row?.querySelector("select[data-variant-id-select]")
    const variantId = variantSelect ? variantSelect.value : null

    this.element.querySelectorAll("input[data-primary-cb]").forEach(cb => {
      if (cb === event.target) return
      const cbRow = cb.closest("[data-line-row]")
      const cbVariantSelect = cbRow?.querySelector("select[data-variant-id-select]")
      const cbVariantId = cbVariantSelect ? cbVariantSelect.value : null
      if (cbVariantId === variantId) cb.checked = false
    })
  }

  async generate(event) {
    const btn = event.currentTarget
    const originalHtml = btn.innerHTML
    btn.disabled = true

    try {
      const useSave = this.hasGenerateSaveUrlValue && this.generateSaveUrlValue.length > 0
      // Which variant (if any) to assign the generated barcode to.
      const variantId = this.hasVariantSelectTarget ? (this.variantSelectTarget.value || "") : ""

      let code, savedId, isPrimary, savedVariantId

      if (useSave) {
        const csrf = document.querySelector('meta[name="csrf-token"]')?.content
        const body = new URLSearchParams()
        if (variantId) body.append("variant_id", variantId)
        const res = await fetch(this.generateSaveUrlValue, {
          method:  "POST",
          headers: { Accept: "application/json", "X-CSRF-Token": csrf },
          body:    body
        })
        if (!res.ok) throw new Error(`HTTP ${res.status}`)
        const data = await res.json()
        if (data.error) throw new Error(data.error)
        code           = data.barcode
        savedId        = data.id
        isPrimary      = data.is_primary
        savedVariantId = data.variant_id != null ? String(data.variant_id) : ""
      } else {
        const res = await fetch(this.generateUrlValue, { headers: { Accept: "application/json" } })
        if (!res.ok) throw new Error(`HTTP ${res.status}`)
        const data = await res.json()
        code = data.code
      }

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

      // Set barcode type to "internal" (targets the type select, not the variant select)
      const typeSelect = newRow.querySelector("select:not([data-variant-id-select])")
      if (typeSelect) typeSelect.value = "internal"

      // Pre-select the variant in the new row's variant dropdown
      const effectiveVariantId = savedVariantId ?? variantId
      if (effectiveVariantId) {
        const variantSel = newRow.querySelector("select[data-variant-id-select]")
        if (variantSel) variantSel.value = effectiveVariantId
      }

      if (savedId) {
        // Barcode already persisted — inject hidden id so the form submit
        // does UPDATE on this record, not a second INSERT.
        const idField = document.createElement("input")
        idField.type  = "hidden"
        idField.name  = (input?.name || "").replace(/\[barcode\]$/, "[id]")
        idField.value = savedId
        if (idField.name) newRow.prepend(idField)
      }

      // Auto-mark primary and demote any sibling primary in the same variant group.
      const noPrimaryYet = !this.element.querySelector("input[data-primary-cb]:checked")
      const shouldBePrimary = savedId ? isPrimary : noPrimaryYet
      if (shouldBePrimary) {
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
      btn.disabled    = false
      btn.innerHTML   = originalHtml
    }
  }
}
