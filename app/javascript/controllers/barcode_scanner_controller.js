import { Controller } from "@hotwired/stimulus"
import { selectProduct } from "lib/product_option"

// Reusable barcode-scanner input for inventory document forms (goods receipt,
// stock issue, stock transfer — and later stock count / purchase orders /
// adjustments). A hardware scanner behaves as a keyboard that types the code then
// sends Enter, so we trigger on the Enter key, with a short debounce as a fallback
// for scanners that omit the suffix.
//
// On a scan we resolve the product — first against the products already chosen
// on the form's lines (instant, offline), then via the shared lookup endpoint —
// then add or select its line-item row and move focus to that row's quantity
// field. Line pickers (product-combobox) hold only their chosen products, so a
// remotely found product gets its <option> added (lib/product_option.js).
//
// Mounted on a wrapper inside the form; it cooperates with `line-items` purely
// through the DOM (the rows/template/emptyState markers), so no controller
// coupling is required and the same input works on any line-items form.
export default class extends Controller {
  static targets = ["input", "feedback"]
  // increment (opt-in, e.g. the stock transfer form): scanning a product that
  // is already on a line adds one to that line instead of only focusing it,
  // so repeated scans count units. Every other form keeps the default.
  static values  = { lookupUrl: String, mode: { type: String, default: "select" }, increment: { type: Boolean, default: false } }

  // Scanner's Enter suffix: swallow it so the form doesn't submit, then process.
  scan(event) {
    event.preventDefault()
    this.#clearDebounce()
    this.#process()
  }

  // Fallback for scanners that don't append Enter.
  debouncedScan() {
    this.#clearDebounce()
    this._timer = setTimeout(() => this.#process(), 120)
  }

  async #process() {
    const code = this.inputTarget.value.trim()
    if (!code) return
    if (this.modeValue === "rows") return this.#processRows(code)
    if (this.incrementValue) {
      // Increment mode: a hardware scanner fires scans faster than a remote
      // lookup returns — take the code now and handle the scans strictly in
      // order, so the second scan of a product finds its line and adds one.
      this.inputTarget.value = ""
      this._queue = (this._queue || Promise.resolve()).then(() => this.#processCode(code)).catch(() => {})
      return this._queue
    }
    return this.#processCode(code)
  }

  async #processCode(code) {
    const local = this.#matchLocally(code)
    if (local) { this.#useProduct(local); return }

    const remote = await this.#lookupRemote(code)
    if (remote) this.#useProduct(remote)
    else this.#notFound(code)
  }

  // Rows mode (stock count): each preloaded row carries the product's barcode/sku,
  // so a scan focuses that row's counted field; an unloaded product is appended
  // from the template via the shared lookup endpoint.
  async #processRows(code) {
    const row = this.#findRow(code)
    if (row) { this.#focusRow(row); this.#reset(); return }

    const product = await this.#lookupProduct(code)
    if (!product || product.error) {
      this.#notFound(code)
      return
    }
    // The server resolves every barcode of a product: a code this sheet's row
    // doesn't carry may still be a product already on it — focus that row.
    const onSheet = this.#rowsContainer().querySelector(`[data-line-row][data-product-id="${CSS.escape(String(product.id))}"]`)
    if (onSheet) { this.#focusRow(onSheet); this.#reset(); return }
    this.#addCountRow(product)
  }

  // Match across all rows (even those hidden by an active filter) so a scan never
  // creates a duplicate of a product already on the sheet.
  #findRow(code) {
    const needle = code.toLowerCase()
    return Array.from(this.#rowsContainer().querySelectorAll("[data-line-row]"))
      .find(r => this.#matchesAnyBarcode(r, needle) ||
                 (r.dataset.sku || "").toLowerCase() === needle)
  }

  // Check if a code matches either the primary barcode or any barcode in the
  // pipe-separated data-barcodes list (populated when product_barcodes are preloaded).
  #matchesAnyBarcode(element, needle) {
    const primary = (element.dataset.barcode || "").toLowerCase()
    if (primary === needle) return true
    const all = (element.dataset.barcodes || "").split("|")
    return all.some(b => b.toLowerCase() === needle)
  }

  #focusRow(row) {
    row.hidden = false   // reveal it if a filter had hidden it
    const qty = row.querySelector("[data-quantity-field]") || row.querySelector('input[type="number"]')
    qty?.focus()
    qty?.select?.()
  }

  #addCountRow(product) {
    const allBarcodes = Array.isArray(product.barcodes) ? product.barcodes : (product.barcode ? [ product.barcode ] : [])
    const html = this.#template().innerHTML
      .replace(/NEW_INDEX/g, Date.now())
      .replace(/__PID__/g, product.id)
      .replace(/__NAME__/g, this.#escape(product.name))
      .replace(/__SKU__/g, this.#escape(product.sku))
      .replace(/__BARCODE__/g, this.#escape(product.barcode || ""))
      .replace(/__BARCODES__/g, this.#escape(allBarcodes.join("|")))
    this.#rowsContainer().insertAdjacentHTML("beforeend", html)
    this.#focusRow(this.#rowsContainer().lastElementChild)
    this.#reset()
  }

  #escape(value) {
    const el = document.createElement("div")
    el.textContent = value == null ? "" : String(value)
    return el.innerHTML
  }

  #form()          { return this.element.closest("form") }
  #rowsContainer() { return this.#form().querySelector('[data-line-items-target="rows"]') }
  #template()      { return this.#form().querySelector('[data-line-items-target="template"]') }

  // Match a product by barcode (then SKU) against the products already chosen on
  // the form's lines — their <option>s carry the barcodes / SKU.
  #matchLocally(code) {
    const needle = code.toLowerCase()
    const options = Array.from(this.#rowsContainer()?.querySelectorAll("[data-line-row] select option") || [])
                         .filter(o => o.value)
    const opt = options.find(o => this.#matchesAnyBarcode(o, needle)) ||
                options.find(o => (o.dataset.sku || "").toLowerCase() === needle)
    return opt ? { id: opt.value } : null
  }

  async #lookupRemote(code) {
    const result = await this.#lookupProduct(code)
    if (!result) return null
    return result.id ? result : null
  }

  async #lookupProduct(code) {
    try {
      const res = await fetch(`${this.lookupUrlValue}?code=${encodeURIComponent(code)}`,
                              { headers: { Accept: "application/json" } })
      const data = await res.json()
      return (res.ok || data.error) ? data : null
    } catch {
      return null
    }
  }

  // `product` is { id } for a local match, or the lookup payload for a remote one.
  #useProduct(product) {
    const productId = String(product.id)
    const rows = this.#rowsContainer()
    const productSelect = (row) => row.querySelector("select[data-product-field]") || row.querySelector("select")
    const selects = () => Array.from(rows.querySelectorAll("[data-line-row]:not([hidden])")).map(productSelect).filter(Boolean)

    // Already on a visible row → just focus its quantity (no duplicate row).
    const existing = selects().find(s => s.value === productId)
    if (existing) {
      if (this.incrementValue) this.#incrementRow(existing)
      this.#selectRow(existing)
      return
    }

    // Otherwise reuse the first empty row, or add a fresh one from the template.
    let select = selects().find(s => !s.value)
    if (!select) select = productSelect(this.#addRow())

    if (product.name) {
      selectProduct(select, product) // adds its <option>, then the change event (supplier prefill etc.)
    } else {
      select.value = productId
      select.dispatchEvent(new Event("change", { bubbles: true }))
    }
    if (this.incrementValue) this.#incrementRow(select) // the first scan of a product counts one unit
    this.#selectRow(select)
  }

  #addRow() {
    const html = this.#template().innerHTML.replace(/NEW_INDEX/g, Date.now())
    this.#rowsContainer().insertAdjacentHTML("beforeend", html)
    const empty = this.#form().querySelector('[data-line-items-target="emptyState"]')
    if (empty) empty.hidden = true
    return this.#rowsContainer().lastElementChild
  }

  // One more unit on the line (empty counts as 0), announced like a user edit.
  #incrementRow(select) {
    const row = select.closest("[data-line-row]")
    const qty = row?.querySelector("[data-quantity-field]") || row?.querySelector('input[type="number"]')
    if (!qty) return
    const current = Number.parseFloat(qty.value || "0")
    qty.value = String((Number.isFinite(current) ? current : 0) + 1)
    qty.dispatchEvent(new Event("input", { bubbles: true }))
  }

  #selectRow(select) {
    const row = select.closest("[data-line-row]")
    const qty = row.querySelector("[data-quantity-field]") || row.querySelector('input[type="number"]')
    if (this.incrementValue) {
      // Consecutive scans: keep the focus on the scan input (a hardware
      // scanner types wherever the focus is), and show which line changed.
      // The input was cleared when this scan was taken; clearing it again
      // here would wipe the NEXT scan the scanner is already typing.
      row.scrollIntoView?.({ block: "nearest" })
      if (this.hasFeedbackTarget) this.feedbackTarget.hidden = true
      this.inputTarget.focus()
      return
    }
    qty?.focus()
    qty?.select?.()
    this.#reset()
  }

  #reset() {
    this.inputTarget.value = ""
    if (this.hasFeedbackTarget) this.feedbackTarget.hidden = true
  }

  #notFound(code) {
    if (this.hasFeedbackTarget) {
      const tpl = this.feedbackTarget.dataset.notFound || 'No product found for "%{code}"'
      this.feedbackTarget.textContent = tpl.replace("%{code}", code)
      this.feedbackTarget.hidden = false
    }
    this.inputTarget.select()
  }

  #clearDebounce() {
    if (this._timer) { clearTimeout(this._timer); this._timer = null }
  }
}
