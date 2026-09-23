import { Controller } from "@hotwired/stimulus"

// Drives the Low Stock Alerts table on the Inventory Dashboard:
//   1. Checkbox selection + a live "selected total" (reorder_quantity * unit_price).
//   2. The "إنشاء طلب شراء" review modal: groups the checked rows by supplier
//      (product.default_supplier, or a manual choice for products with none),
//      lets the requested quantity/unit price be adjusted per row, and shows
//      one sub-total per supplier plus a grand total — before anything is
//      created server-side (Inventory::PurchaseRequestCreator makes ONE
//      Purchase Request per supplier group on confirm).
// Nothing here ever touches inventory — this is a client-side planning view
// only; the actual creation happens in one POST on #submitReview.
export default class extends Controller {
  static targets = [
    "countBadge", "totalBadge", "createBtn",
    "modal", "reviewMissing", "reviewGroups",
    "reviewRequestCount", "reviewItemCount", "reviewGrandTotal",
    "reviewForm", "formFields", "confirmBtn",
  ]

  static values = {
    currencyPrefix: String,
    currencySuffix: String,
    suppliers: Array,
    createUrl: String,
    noSupplierLabel: String,
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
      quantity:     parseFloat(b.dataset.reorderQty) || 0,
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
      const select = event.target
      item.supplierId   = select.value
      item.supplierName = select.value ? select.options[select.selectedIndex].text : ""
      this._renderReview()
    } else if (field === "quantity") {
      item.quantity = parseFloat(event.target.value) || 0
      this._recomputeTotals()
    } else if (field === "unitPrice") {
      item.unitPrice = event.target.value
      this._recomputeTotals()
    }
  }

  submitReview(event) {
    if (this._hasMissingSupplier() || this._hasInvalidPrice()) {
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

  _groups() {
    const map = new Map()
    this.reviewItems.forEach((item) => {
      const key = item.supplierId || ""
      if (!map.has(key)) map.set(key, [])
      map.get(key).push(item)
    })
    return map
  }

  _renderReview() {
    const groups = this._groups()
    let html = ""

    groups.forEach((items, supplierId) => {
      const supplierName = supplierId ? items[0].supplierName : this.noSupplierLabelValue
      const groupTotal    = items.reduce((sum, i) => sum + this._lineTotal(i), 0)

      html += `<div class="review-group" data-supplier-key="${this._esc(supplierId)}" style="margin-bottom: var(--space-4); border: 1px solid var(--border-color, #e0e0e0); border-radius: 8px; padding: var(--space-3);">`
      html += `<div class="flex items-center justify-between" style="margin-bottom: var(--space-2);">`
      html += `<strong>${this._esc(supplierName)}</strong>`
      html += `<span class="td-secondary review-group-total" data-supplier-key="${this._esc(supplierId)}">${this._formatCurrency(groupTotal)}</span>`
      html += `</div>`

      items.forEach((item) => {
        const needsSupplier = !item.supplierId
        html += `<div class="flex items-center" style="gap: var(--space-3); padding: var(--space-2) 0; border-top: 1px solid var(--border-color, #f0f0f0); flex-wrap: wrap;">`
        html += `<div style="flex: 2; min-width: 140px;">${this._esc(item.productName)} <span class="td-secondary">(${this._esc(item.sku)})</span></div>`

        if (needsSupplier) {
          html += `<select data-action="change->low-stock-selection#reviewFieldChanged" data-field="supplierId" data-item-index="${item.index}" class="filter-bar__select" style="flex: 1; min-width: 140px;">`
          html += `<option value="">${this._esc(this.noSupplierLabelValue)}</option>`
          this.suppliersValue.forEach((s) => {
            html += `<option value="${s.id}">${this._esc(s.name)}</option>`
          })
          html += `</select>`
        }

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

    const missing = this._hasMissingSupplier()
    if (this.hasReviewMissingTarget) this.reviewMissingTarget.style.display = missing ? "" : "none"
    if (this.hasConfirmBtnTarget)    this.confirmBtnTarget.disabled = missing || this._hasInvalidPrice()
  }

  _lineTotal(item) {
    const price = parseFloat(item.unitPrice)
    if (!price || price <= 0) return 0
    return item.quantity * price
  }

  _hasMissingSupplier() {
    return this.reviewItems.some((i) => !i.supplierId)
  }

  _hasInvalidPrice() {
    return this.reviewItems.some((i) => !(parseFloat(i.unitPrice) > 0) || !(i.quantity > 0))
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
