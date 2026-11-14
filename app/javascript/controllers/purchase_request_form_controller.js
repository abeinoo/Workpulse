import { Controller } from "@hotwired/stimulus"
import { ensureProductOption } from "lib/product_option"

// The Purchase Request form (new + draft edit — see PurchaseRequestPolicy#update?):
//   1. Live line-total / grand-total recalculation. Pure display: the
//      authoritative total is always recomputed server-side
//      (PurchaseRequestItem#compute_total_cost / PurchaseRequest#total_amount).
//   2. Duplicate prevention: a product may appear once per request (the
//      warehouse belongs to the whole request). A change that would repeat an
//      existing line is reverted and the existing line is pointed out instead
//      (Inventory::PurchaseRequestCreator / PurchaseRequestUpdater reject
//      duplicates server-side too).
//   3. Line supplier: picking a product fills that line's supplier with the
//      product's default supplier (blank when it has none) — unless the line's
//      supplier was deliberately chosen (neither blank nor the previous
//      product's default), which is kept with a short note. The user may
//      change it; that never touches the product.
//   Also drives the PR page's single-line item editor (_item_editor), where
//   baseTotal is the request's other lines so the total shows the result.
//   4. The optional Low Stock picker (new form only): checked rows become
//      ordinary lines — Low Stock is a source of products, never a requirement.
//      Only rows of the request's warehouse (or total-stock rows) can be added,
//      and never a product already on the request: such rows are left out of
//      the list when it opens and skipped again when adding. Select all /
//      indeterminate, a live count, and quantity checks (> 0) that keep the
//      modal open; it closes only on Add, Cancel or Escape. The checkboxes and
//      quantity inputs are the only selection state.
export default class extends Controller {
  static targets = ["row", "lineTotal", "grandTotal", "warehouse", "duplicateNotice", "lowStockModal"]
  static values = { currencyPrefix: String, currencySuffix: String, duplicateMessage: String, baseTotal: Number }

  connect() {
    this.element.querySelectorAll("[data-product-field]").forEach((field) => {
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
    let grandTotal = this.baseTotalValue

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
    const previousDefault = this._defaultSupplierOf(select, select.dataset.previousValue)
    select.dataset.previousValue = select.value

    this._applyProductSupplier(row, previousDefault, select.selectedOptions[0]?.dataset.defaultSupplierId)
  }

  // ── Low Stock picker ────────────────────────────────────────────────────

  openLowStock() {
    if (!this.hasLowStockModalTarget) return

    // Rows that can't be added are not offered at all; entered quantities are kept.
    let unavailable = 0
    this._pickerRows().forEach((tr) => {
      const blocked = Boolean(this._pickerRowLine(tr)) || this._otherWarehouse(tr)
      const check   = tr.querySelector("[data-low-stock-check]")
      check.checked  = false
      check.disabled = blocked
      tr.hidden      = blocked
      if (blocked) unavailable += 1
    })

    const note = this.lowStockModalTarget.querySelector("[data-low-stock-hidden-note]")
    if (note) {
      note.textContent = this.lowStockModalTarget.dataset.hiddenNote.replace("__COUNT__", unavailable)
      note.hidden = unavailable === 0
    }
    this._updateLowStockSelection()

    this.lowStockModalTarget.style.display = ""
    requestAnimationFrame(() => {
      const modal = this.lowStockModalTarget
      ;(modal.querySelector("[data-low-stock-select-all]:not([disabled])") || modal.querySelector("button"))?.focus()
    })
  }

  closeLowStock() {
    if (this.hasLowStockModalTarget) this.lowStockModalTarget.style.display = "none"
  }

  // Header checkbox: (de)selects every row currently offered.
  lowStockToggleAll(event) {
    this._availablePickerRows().forEach((tr) => {
      tr.querySelector("[data-low-stock-check]").checked = event.target.checked
    })
    this._updateLowStockSelection()
  }

  lowStockSelectionChanged() {
    this._updateLowStockSelection()
  }

  addFromLowStock() {
    // Nothing selected, or a selected quantity that isn't > 0: stay open.
    if (this._updateLowStockSelection().blocked) return
    this._hideDuplicateNotice()

    this._pickerRows().forEach((tr) => {
      if (!tr.querySelector("[data-low-stock-check]").checked) return

      if (this._pickerRowLine(tr)) return // added since the picker opened — never duplicate
      // One warehouse per request: the first warehouse-specific row picked
      // while none is chosen sets it; rows of any other warehouse are skipped.
      // A total-stock row (no warehouse) fits whatever the request uses.
      if (this._otherWarehouse(tr)) return
      if (tr.dataset.warehouseId && this.hasWarehouseTarget && !this.warehouseTarget.value) {
        this.warehouseTarget.value = tr.dataset.warehouseId
      }

      const row = this._blankRow() || this._appendRow()
      this._setProduct(row, { id: tr.dataset.productId, name: tr.dataset.productName, sku: tr.dataset.sku,
                              thumb: tr.dataset.thumb, default_supplier_id: tr.dataset.supplierId })
      this._setField(row, "[data-quantity-field]", tr.querySelector("[data-low-stock-quantity]").value)
      if (tr.dataset.unitPrice) this._setField(row, "[data-price-field]", tr.dataset.unitPrice)
      this._prefillSupplier(row, tr.dataset.supplierId)
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

  _availablePickerRows() {
    return this._pickerRows().filter((tr) => !tr.hidden)
  }

  // Select-all state, the count, the Add button and the quantity check, all
  // derived from the checkboxes and quantity inputs. Returns { blocked }.
  _updateLowStockSelection() {
    if (!this.hasLowStockModalTarget) return { blocked: true }

    const modal     = this.lowStockModalTarget
    const available = this._availablePickerRows()
    const selected  = available.filter((tr) => tr.querySelector("[data-low-stock-check]").checked)

    let invalid = false
    available.forEach((tr) => {
      const input = tr.querySelector("[data-low-stock-quantity]")
      const qty   = parseFloat(input.value)
      const bad   = tr.querySelector("[data-low-stock-check]").checked && !(qty > 0)
      if (bad) invalid = true
      input.classList.toggle("is-error", bad)
      if (bad) input.setAttribute("aria-invalid", "true")
      else input.removeAttribute("aria-invalid")
      tr.classList.toggle("is-selected", tr.querySelector("[data-low-stock-check]").checked)
    })

    const all = modal.querySelector("[data-low-stock-select-all]")
    if (all) {
      all.disabled      = available.length === 0
      all.checked       = available.length > 0 && selected.length === available.length
      all.indeterminate = selected.length > 0 && selected.length < available.length
    }

    const summary = modal.querySelector("[data-low-stock-summary]")
    if (summary) {
      summary.textContent = selected.length === 0
        ? modal.dataset.summaryNone
        : modal.dataset.summarySome.replace("__COUNT__", selected.length)
    }

    const invalidNote = modal.querySelector("[data-low-stock-invalid]")
    if (invalidNote) invalidNote.hidden = !invalid

    const blocked = selected.length === 0 || invalid
    const add = modal.querySelector("[data-low-stock-add]")
    if (add) {
      add.disabled    = blocked
      add.textContent = modal.dataset.addLabel.replace("__COUNT__", selected.length)
    }
    return { blocked }
  }

  _lineKey(row) {
    return row.querySelector("[data-product-field]")?.value || ""
  }

  // The visible line already holding this product, ignoring `except`. Lines
  // with no product chosen never count.
  _findLine(key, except = null) {
    if (!key) return null
    return this._visibleRows().find((row) => row !== except && this._lineKey(row) === key)
  }

  // The line already covering a picker row (same product).
  _pickerRowLine(tr) {
    return this._findLine(tr.dataset.productId)
  }

  // A warehouse-specific picker row for a warehouse other than the one the
  // request already uses.
  _otherWarehouse(tr) {
    const chosen = this.hasWarehouseTarget ? this.warehouseTarget.value : ""
    return Boolean(tr.dataset.warehouseId && chosen && tr.dataset.warehouseId !== chosen)
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

  // A product set by code (Low Stock picker): its <option> first — the line's
  // picker holds only chosen products — then the value, without a user change.
  _setProduct(row, product) {
    const select = row.querySelector("[data-product-field]")
    if (!select) return
    ensureProductOption(select, product)
    this._setField(row, "[data-product-field]", String(product.id))
  }

  // Keeps the line's product picker (product-combobox) showing a value set
  // here programmatically, without firing the line's change listeners.
  _syncSearchable(select) {
    select.dispatchEvent(new CustomEvent("pcombo:refresh"))
  }

  // Sets a line's supplier to the given (product default / Low Stock)
  // supplier, or clears it when there is none — a newly picked product starts
  // from its own default. The user may change it afterwards.
  _prefillSupplier(row, supplierId) {
    const select = row?.querySelector("[data-supplier-field]")
    if (!select) return
    const known = supplierId && select.querySelector(`option[value="${CSS.escape(supplierId)}"]`)
    select.value = known ? supplierId : ""
  }

  _defaultSupplierOf(select, productId) {
    if (!productId) return ""
    return select.querySelector(`option[value="${CSS.escape(productId)}"]`)?.dataset.defaultSupplierId || ""
  }

  // A changed product brings its default supplier only when the line's
  // supplier wasn't deliberately chosen: blank, or the previous product's own
  // default. Otherwise the chosen supplier stays and the line says so.
  _applyProductSupplier(row, previousDefault, newDefault) {
    const select = row?.querySelector("[data-supplier-field]")
    if (!select) return
    const note   = row.querySelector("[data-supplier-kept-note]")
    const chosen = select.value && select.value !== previousDefault
    if (chosen) {
      if (note) note.hidden = (newDefault || "") === select.value
      return
    }
    if (note) note.hidden = true
    this._prefillSupplier(row, newDefault)
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
