import { Controller } from "@hotwired/stimulus"

// Drives the Low Stock Alerts table on the Inventory Dashboard:
//   1. Checkbox selection + a live "selected total" (reorder_quantity * unit_price).
//   2. The "إنشاء طلب شراء" review modal: groups the checked rows by supplier,
//      lets the supplier (product.default_supplier is only the suggestion),
//      requested quantity and unit price be changed per row, and shows one
//      item count + sub-total per supplier group plus a grand total — before
//      anything is created server-side (Inventory::PurchaseRequestCreator
//      makes ONE Purchase Request per supplier group on confirm). Changing a
//      row's supplier MOVES it to that supplier's group (created if new); "بدون
//      مورد" is a valid choice — those rows become one no-supplier draft
//      request, which needs a supplier before it can be submitted for approval.
// Nothing here ever touches inventory — this is a client-side planning view
// only; the actual creation happens in one POST on #submitReview.
export default class extends Controller {
  static targets = [
    "countBadge", "totalBadge", "createBtn",
    "modal", "reviewMissing", "reviewInvalid", "reviewGroups",
    "reviewRequestCount", "reviewItemCount", "reviewGrandTotal",
    "reviewForm", "formFields", "confirmBtn",
  ]

  static values = {
    currencyPrefix: String,
    currencySuffix: String,
    suppliers: Array,
    createUrl: String,
    noSupplierLabel: String,
    chooseSupplierLabel: String,
    groupTitle: String,
    groupTitleNoSupplier: String,
    groupItemsLabel: String,
    groupTotalLabel: String,
  }

  connect() {
    this._syncSummary()
    this.reviewItems = []
    this._onKeydown = this._handleKeydown.bind(this)
    document.addEventListener("keydown", this._onKeydown)
  }

  disconnect() {
    document.removeEventListener("keydown", this._onKeydown)
  }

  // ── Row selection (table) ───────────────────────────────────────────────

  get allBoxes() {
    return Array.from(this.element.querySelectorAll(".low-stock-check-row"))
  }

  get checkedBoxes() {
    return this.allBoxes.filter((b) => b.checked)
  }

  toggleAll(event) {
    const checked = event.target.checked
    this.allBoxes.forEach((b) => { b.checked = checked })
    this._syncSummary()
  }

  rowChanged() {
    const master = this.element.querySelector(".low-stock-check-all")
    if (master) {
      const all     = this.allBoxes
      const checked = this.checkedBoxes
      master.checked       = all.length > 0 && checked.length === all.length
      master.indeterminate = checked.length > 0 && checked.length < all.length
    }
    this._syncSummary()
  }

  get selectedTotal() {
    return this.checkedBoxes.reduce(
      (sum, b) => sum + (parseFloat(b.dataset.amount) || 0),
      0
    )
  }

  _syncSummary() {
    const count = this.checkedBoxes.length
    if (this.hasCountBadgeTarget) this.countBadgeTarget.textContent = count
    if (this.hasTotalBadgeTarget) this.totalBadgeTarget.textContent = this._formatCurrency(this.selectedTotal)
    if (this.hasCreateBtnTarget)  this.createBtnTarget.disabled = count === 0
  }

  // ── Review modal ─────────────────────────────────────────────────────────

  openReview() {
    const boxes = this.checkedBoxes
    if (boxes.length === 0) return

    this.idempotencyKey = this._uuid()
    this.reviewItems = boxes.map((b, index) => ({
      index,
      productId:    b.dataset.productId,
      productName:  b.dataset.productName,
      sku:          b.dataset.sku,
      warehouseId:  b.dataset.warehouseId || "",
      // No reorder quantity configured -> start at 1 (same as the general
      // form's Low Stock picker) rather than an invalid 0 line.
      quantity:     parseFloat(b.dataset.reorderQty) > 0 ? parseFloat(b.dataset.reorderQty) : 1,
      unitPrice:    b.dataset.unitPrice || "",
      supplierId:   b.dataset.supplierId || "",
      supplierName: b.dataset.supplierName || "",
    }))

    this._renderReview()
    if (this.hasModalTarget) {
      this.modalTarget.style.display = ""
      requestAnimationFrame(() => {
        const first = this.modalTarget.querySelector(".modal-card input, .modal-card select, .modal-card button")
        if (first) first.focus()
      })
    }
  }

  closeModal() {
    if (this.hasModalTarget) this.modalTarget.style.display = "none"
    if (this.hasCreateBtnTarget) this.createBtnTarget.focus()
  }

  overlayClick(event) {
    if (event.target === this.modalTarget) this.closeModal()
  }

  // A row's quantity/unit-price/supplier input changed — update in-memory
  // state, then either recompute totals in place (quantity/price: keeps
  // keyboard focus) or fully regroup (supplier: a row may need to move to a
  // different/new supplier group).
  reviewFieldChanged(event) {
    const field = event.target.dataset.field
    const index = parseInt(event.target.dataset.itemIndex, 10)
    const item  = this.reviewItems.find((i) => i.index === index)
    if (!item) return

    if (field === "supplierId") {
      // Only the grouping changes. There is no supplier-specific price list
      // (prices come from the product's average cost), so the row's unit
      // price — suggested or typed by the user — is kept as-is.
      item.supplierId   = event.target.value
      item.supplierName = this._supplierName(item.supplierId)
      this._renderReview()
      this.reviewGroupsTarget?.querySelector(`select[data-item-index="${index}"]`)?.focus()
    } else if (field === "quantity") {
      item.quantity = parseFloat(event.target.value) || 0
      this._recomputeTotals()
    } else if (field === "unitPrice") {
      item.unitPrice = event.target.value
      this._recomputeTotals()
    }
  }

  submitReview(event) {
    if (this._hasInvalidLine()) {
      event.preventDefault()
      return
    }

    // Inject one hidden-input block per selected item, plus the one
    // idempotency key covering the whole multi-supplier operation, right
    // before the native form submits (classic, non-Turbo submit — see
    // `local: true` on the form — so this is the last chance to build them).
    if (this.hasFormFieldsTarget) {
      this.formFieldsTarget.innerHTML = this._hiddenFieldsMarkup()
    }

    if (this.hasConfirmBtnTarget) this.confirmBtnTarget.disabled = true
    // Clearing the on-page selection happens on the next page load (after a
    // successful redirect) — a failed submission re-renders this same page
    // with the selection untouched, matching "cancel keeps the selection."
  }

  // ── Rendering ────────────────────────────────────────────────────────────

  // supplierId ("" = no supplier) -> items. Each item lives in exactly one
  // group — its CURRENT supplier — so a moved row is never duplicated. The
  // no-supplier group is always listed last.
  _groups() {
    const map = new Map()
    this.reviewItems.forEach((item) => {
      const key = item.supplierId || ""
      if (!map.has(key)) map.set(key, [])
      map.get(key).push(item)
    })
    if (map.has("")) {
      const unassigned = map.get("")
      map.delete("")
      map.set("", unassigned)
    }
    return map
  }

  _renderReview() {
    const groups = this._groups()
    let html = ""

    groups.forEach((items, supplierId) => {
      const title = supplierId
        ? this.groupTitleValue.replace("%{supplier}", items[0].supplierName)
        : this.groupTitleNoSupplierValue
      const groupTotal = items.reduce((sum, i) => sum + this._lineTotal(i), 0)
      const key = this._esc(supplierId)

      html += `<div class="review-group" data-supplier-key="${key}" style="margin-bottom: var(--space-4); border: 1px solid var(--border-color, #e0e0e0); border-radius: 8px; padding: var(--space-3);">`
      html += `<div class="flex items-center justify-between" style="margin-bottom: var(--space-2); flex-wrap: wrap; gap: var(--space-2);">`
      html += `<strong class="review-group-title">${this._esc(title)}</strong>`
      html += `<span class="td-secondary">`
      html += `${this._esc(this.groupItemsLabelValue)}: <strong class="review-group-count" data-supplier-key="${key}">${items.length}</strong>`
      html += ` · ${this._esc(this.groupTotalLabelValue)}: <strong class="review-group-total" data-supplier-key="${key}">${this._formatCurrency(groupTotal)}</strong>`
      html += `</span>`
      html += `</div>`

      items.forEach((item) => {
        html += `<div class="flex items-center review-row" data-item-index="${item.index}" style="gap: var(--space-3); padding: var(--space-2) 0; border-top: 1px solid var(--border-color, #f0f0f0); flex-wrap: wrap;">`
        html += `<div style="flex: 2; min-width: 140px;">${this._esc(item.productName)} <span class="td-secondary">(${this._esc(item.sku)})</span></div>`

        // Always editable — the current supplier is only a suggestion.
        html += `<select data-action="change->low-stock-selection#reviewFieldChanged" data-field="supplierId" data-item-index="${item.index}" class="filter-bar__select" style="flex: 1; min-width: 140px;" aria-label="${this._esc(this.chooseSupplierLabelValue)}">`
        html += `<option value=""${item.supplierId ? "" : " selected"}>${this._esc(this.noSupplierLabelValue)}</option>`
        this.suppliersValue.forEach((s) => {
          const selected = String(s.id) === String(item.supplierId) ? " selected" : ""
          html += `<option value="${s.id}"${selected}>${this._esc(s.name)}</option>`
        })
        html += `</select>`

        html += `<label class="td-secondary" style="display:flex; align-items:center; gap:4px;">`
        html += `<input type="number" min="0.001" step="0.001" value="${item.quantity}" style="width: 80px;" `
        html += `data-action="input->low-stock-selection#reviewFieldChanged" data-field="quantity" data-item-index="${item.index}">`
        html += `</label>`

        html += `<label class="td-secondary" style="display:flex; align-items:center; gap:4px;">`
        html += `<input type="number" min="0.01" step="0.01" value="${this._esc(item.unitPrice)}" style="width: 90px;" placeholder="—" `
        html += `data-action="input->low-stock-selection#reviewFieldChanged" data-field="unitPrice" data-item-index="${item.index}">`
        html += `</label>`

        html += `<span class="review-row-total" data-item-index="${item.index}" style="min-width: 90px; text-align: end;">${this._formatCurrency(this._lineTotal(item))}</span>`
        html += `</div>`
      })

      html += `</div>`
    })

    if (this.hasReviewGroupsTarget) this.reviewGroupsTarget.innerHTML = html
    this._recomputeTotals()
  }

  // Updates numbers only — no DOM rebuild — so typing in a quantity/price
  // field never loses focus or cursor position.
  _recomputeTotals() {
    const groups = this._groups()

    this.reviewItems.forEach((item) => {
      const el = this.reviewGroupsTarget?.querySelector(`.review-row-total[data-item-index="${item.index}"]`)
      if (el) el.textContent = this._formatCurrency(this._lineTotal(item))
    })

    groups.forEach((items, supplierId) => {
      const total = items.reduce((sum, i) => sum + this._lineTotal(i), 0)
      const el = this.reviewGroupsTarget?.querySelector(`.review-group-total[data-supplier-key="${CSS.escape(String(supplierId))}"]`)
      if (el) el.textContent = this._formatCurrency(total)
    })

    const grandTotal = this.reviewItems.reduce((sum, i) => sum + this._lineTotal(i), 0)
    if (this.hasReviewRequestCountTarget) this.reviewRequestCountTarget.textContent = groups.size
    if (this.hasReviewItemCountTarget)    this.reviewItemCountTarget.textContent = this.reviewItems.length
    if (this.hasReviewGrandTotalTarget)   this.reviewGrandTotalTarget.textContent = this._formatCurrency(grandTotal)

    // Informational only: rows without a supplier still become a (draft)
    // request; the supplier is required later, at submit for approval.
    if (this.hasReviewMissingTarget) this.reviewMissingTarget.style.display = this._hasMissingSupplier() ? "" : "none"
    // Only a bad quantity/price blocks Confirm — never a missing supplier —
    // and the offending inputs are marked so the reason is visible.
    this._markInvalidInputs()
    const invalid = this._hasInvalidLine()
    if (this.hasReviewInvalidTarget) this.reviewInvalidTarget.style.display = invalid ? "" : "none"
    if (this.hasConfirmBtnTarget)    this.confirmBtnTarget.disabled = invalid || this.reviewItems.length === 0
  }

  _lineTotal(item) {
    const price = parseFloat(item.unitPrice)
    if (!price || price <= 0) return 0
    return item.quantity * price
  }

  _hasMissingSupplier() {
    return this.reviewItems.some((i) => !i.supplierId)
  }

  _supplierName(supplierId) {
    if (!supplierId) return ""
    const supplier = this.suppliersValue.find((s) => String(s.id) === String(supplierId))
    return supplier ? supplier.name : ""
  }

  _invalidQuantity(item) { return !(item.quantity > 0) }
  _invalidPrice(item)    { return !(parseFloat(item.unitPrice) > 0) }

  _hasInvalidLine() {
    return this.reviewItems.some((i) => this._invalidQuantity(i) || this._invalidPrice(i))
  }

  _markInvalidInputs() {
    this.reviewItems.forEach((item) => {
      const row = this.reviewGroupsTarget?.querySelector(`.review-row[data-item-index="${item.index}"]`)
      if (!row) return
      this._setInvalid(row.querySelector("input[data-field='quantity']"), this._invalidQuantity(item))
      this._setInvalid(row.querySelector("input[data-field='unitPrice']"), this._invalidPrice(item))
    })
  }

  _setInvalid(input, invalid) {
    if (!input) return
    if (invalid) input.setAttribute("aria-invalid", "true")
    else input.removeAttribute("aria-invalid")
    input.style.outline = invalid ? "2px solid var(--color-danger, #c62828)" : ""
  }

  _hiddenFieldsMarkup() {
    let html = `<input type="hidden" name="idempotency_key" value="${this._esc(this.idempotencyKey)}">`
    this.reviewItems.forEach((item) => {
      html += `<input type="hidden" name="items[][product_id]" value="${this._esc(item.productId)}">`
      html += `<input type="hidden" name="items[][quantity]" value="${item.quantity}">`
      html += `<input type="hidden" name="items[][unit_price]" value="${this._esc(item.unitPrice)}">`
      html += `<input type="hidden" name="items[][supplier_id]" value="${this._esc(item.supplierId)}">`
      html += `<input type="hidden" name="items[][source_warehouse_id]" value="${this._esc(item.warehouseId)}">`
    })
    return html
  }

  // ── Helpers ──────────────────────────────────────────────────────────────

  _handleKeydown(event) {
    if (!this.hasModalTarget || this.modalTarget.style.display === "none") return
    if (event.key === "Escape") this.closeModal()
  }

  _uuid() {
    if (window.crypto && window.crypto.randomUUID) return window.crypto.randomUUID()
    return "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx".replace(/[xy]/g, (c) => {
      const r = (Math.random() * 16) | 0
      const v = c === "x" ? r : (r & 0x3) | 0x8
      return v.toString(16)
    })
  }

  _esc(value) {
    return String(value ?? "").replace(/[&<>"']/g, (c) => (
      { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]
    ))
  }

  // Formats a number to match the server's format_currency helper (precision 2).
  _formatCurrency(value) {
    const num = value.toLocaleString("en-US", {
      minimumFractionDigits: 2,
      maximumFractionDigits: 2,
    })
    return `${this.currencyPrefixValue}${num}${this.currencySuffixValue}`
  }
}
