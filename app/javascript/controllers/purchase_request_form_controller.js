import { Controller } from "@hotwired/stimulus"

// The Purchase Request form (new + draft edit — see PurchaseRequestPolicy#update?):
//   1. Live line-total / grand-total recalculation. Pure display: the
//      authoritative total is always recomputed server-side
//      (PurchaseRequestItem#compute_total_cost / PurchaseRequest#total_amount).
//   2. Duplicate prevention: a product may appear once per warehouse. A
//      change that would repeat an existing line is reverted and the existing
//      line is pointed out instead (Inventory::PurchaseRequestCreator rejects
//      duplicates server-side too).
//   3. The optional Low Stock picker (new form only): checked rows become
//      ordinary lines — Low Stock is a source of products, never a requirement.
export default class extends Controller {
  static targets = ["row", "lineTotal", "grandTotal", "supplier", "duplicateNotice", "lowStockModal"]
  static values = { currencyPrefix: String, currencySuffix: String, duplicateMessage: String }

  connect() {
    this.element.querySelectorAll("[data-product-field], [data-warehouse-field]").forEach((field) => {
      field.dataset.previousValue = field.value
    })
    this.recalculate()
    this._onKeydown = (event) => {
      if (event.key === "Escape" && this._lowStockOpen()) this.closeLowStock()
    }
    document.addEventListener("keydown", this._onKeydown)
  }

  disconnect() {
    document.removeEventListener("keydown", this._onKeydown)
  }

  recalculate() {
    let grandTotal = 0

    this.rowTargets.forEach((row) => {
      if (row.hidden) return

      const qty   = parseFloat(row.querySelector("[data-quantity-field]")?.value) || 0
      const price = parseFloat(row.querySelector("[data-price-field]")?.value) || 0
      const total = qty * price
      grandTotal += total

      const cell = row.querySelector('[data-purchase-request-form-target="lineTotal"]')
      if (cell) cell.textContent = this._formatCurrency(total)
    })

    if (this.hasGrandTotalTarget) this.grandTotalTarget.textContent = this._formatCurrency(grandTotal)
  }

  // ── Duplicate prevention ────────────────────────────────────────────────

  lineKeyChanged(event) {
    const select = event.target
    const row    = select.closest("[data-line-row]")
    this._hideDuplicateNotice()

    const existing = this._findLine(this._lineKey(row), row)
    if (existing) {
      select.value = select.dataset.previousValue || ""
      this._syncSearchable(select)
      this._showDuplicate(existing)
      return
    }
    select.dataset.previousValue = select.value

    if (select.matches("[data-product-field]")) this._prefillSupplier(select)
  }

  // ── Low Stock picker ────────────────────────────────────────────────────

  openLowStock() {
    if (!this.hasLowStockModalTarget) return

    this._pickerRows().forEach((tr) => {
      const added = Boolean(this._pickerRowLine(tr))
      const check = tr.querySelector("[data-low-stock-check]")
      check.checked  = false
      check.disabled = added
      check.hidden   = added
      tr.querySelector("[data-low-stock-added]").hidden = !added
    })

    this.lowStockModalTarget.style.display = ""
    requestAnimationFrame(() => this.lowStockModalTarget.querySelector("input:not([disabled]), button")?.focus())
  }

  closeLowStock() {
    if (this.hasLowStockModalTarget) this.lowStockModalTarget.style.display = "none"
  }

  lowStockOverlayClick(event) {
    if (event.target === this.lowStockModalTarget) this.closeLowStock()
  }

  addFromLowStock() {
    this._hideDuplicateNotice()

    this._pickerRows().forEach((tr) => {
      if (!tr.querySelector("[data-low-stock-check]").checked) return

      if (this._pickerRowLine(tr)) return // added since the picker opened — never duplicate

      const row = this._blankRow() || this._appendRow()
      // A total-stock alert has no warehouse: keep the line's own (preselected
      // or user-chosen) warehouse — the user must still pick one to submit.
      const warehouseId = tr.dataset.warehouseId || row.querySelector("[data-warehouse-field]")?.value
      if (this._findLine(this._key(tr.dataset.productId, warehouseId), row)) return

      this._setField(row, "[data-product-field]", tr.dataset.productId)
      this._setField(row, "[data-warehouse-field]", warehouseId)
      this._setField(row, "[data-quantity-field]", tr.querySelector("[data-low-stock-quantity]").value)
      if (tr.dataset.unitPrice) this._setField(row, "[data-price-field]", tr.dataset.unitPrice)
      this._prefillSupplier(row.querySelector("[data-product-field]"), tr.dataset.supplierId)
    })

    this._syncEmptyState()
    this.recalculate()
    this.closeLowStock()
  }

  // ── Helpers ─────────────────────────────────────────────────────────────

  _visibleRows() {
    return this.rowTargets.filter((row) => !row.hidden)
  }

  _pickerRows() {
    return this.hasLowStockModalTarget ? Array.from(this.lowStockModalTarget.querySelectorAll("[data-low-stock-row]")) : []
  }

  _key(productId, warehouseId) {
    return `${productId || ""}:${warehouseId || ""}`
  }

  _lineKey(row) {
    return this._key(row.querySelector("[data-product-field]")?.value, row.querySelector("[data-warehouse-field]")?.value)
  }

  // The visible line already holding this product+warehouse, ignoring `except`.
  // Lines with no product chosen never count.
  _findLine(key, except = null) {
    if (key.startsWith(":")) return null
    return this._visibleRows().find((row) => row !== except && this._lineKey(row) === key)
  }

  // The line already covering a picker row. A row with no warehouse (total-
  // stock alert) counts as added once its product is on any line.
  _pickerRowLine(tr) {
    if (tr.dataset.warehouseId) return this._findLine(this._key(tr.dataset.productId, tr.dataset.warehouseId))
    return this._visibleRows().find((row) => row.querySelector("[data-product-field]")?.value === tr.dataset.productId)
  }

  _blankRow() {
    return this._visibleRows().find((row) => !row.querySelector("[data-product-field]")?.value)
  }

  // Same template + NEW_INDEX convention as line_items_controller#add.
  _appendRow() {
    const template = this.element.querySelector('template[data-line-items-target="template"]')
    const tbody    = this.element.querySelector('[data-line-items-target="rows"]')
    this._rowSeq = (this._rowSeq || 0) + 1
    tbody.insertAdjacentHTML("beforeend", template.innerHTML.replace(/NEW_INDEX/g, `${Date.now()}${this._rowSeq}`))
    return tbody.lastElementChild
  }

  _setField(row, selector, value) {
    const field = row.querySelector(selector)
    if (!field) return
    field.value = value || ""
    field.dataset.previousValue = field.value
    this._syncSearchable(field)
  }

  // Keeps searchable_select_controller's visible combobox text in step with
  // a value set here programmatically (it only re-reads the <select> itself
  // on its own open/close).
  _syncSearchable(select) {
    const input = select.parentElement?.querySelector(".searchable-select__input")
    if (input) input.value = select.selectedOptions[0]?.text || ""
  }

  // Fills the request's supplier from the product's default supplier, but
  // only while none is chosen — never overrides an explicit choice.
  _prefillSupplier(productSelect, supplierId = null) {
    if (!this.hasSupplierTarget || this.supplierTarget.value) return
    const id = supplierId || productSelect?.selectedOptions[0]?.dataset.defaultSupplierId
    if (id && this.supplierTarget.querySelector(`option[value="${CSS.escape(id)}"]`)) this.supplierTarget.value = id
  }

  _showDuplicate(row) {
    if (this.hasDuplicateNoticeTarget) {
      this.duplicateNoticeTarget.textContent = this.duplicateMessageValue
      this.duplicateNoticeTarget.hidden = false
    }
    row.scrollIntoView({ block: "center", behavior: "smooth" })
    row.querySelector("[data-quantity-field]")?.focus()
  }

  _hideDuplicateNotice() {
    if (this.hasDuplicateNoticeTarget) this.duplicateNoticeTarget.hidden = true
  }

  _syncEmptyState() {
    const empty = this.element.querySelector('[data-line-items-target="emptyState"]')
    if (empty) empty.hidden = this._visibleRows().length > 0
  }

  _lowStockOpen() {
    return this.hasLowStockModalTarget && this.lowStockModalTarget.style.display !== "none"
  }

  _formatCurrency(value) {
    const num = value.toLocaleString("en-US", {
      minimumFractionDigits: 2,
      maximumFractionDigits: 2,
    })
    return `${this.currencyPrefixValue}${num}${this.currencySuffixValue}`
  }
}
