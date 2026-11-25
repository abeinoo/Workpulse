import { Controller } from "@hotwired/stimulus"
import { selectProduct } from "lib/product_option"

// The stock transfer form (inventory/stock_transfers/_form). Presentation and
// convenience only — every figure comes from the server and the server
// re-validates everything under lock when the transfer is submitted, approved
// and dispatched:
//
//  * live figures per line from StockTransfersController#availability (source
//    on hand / reserved by other documents / available, destination on hand /
//    incoming), refreshed when the warehouses or products change;
//  * a per-line and summary warning when a quantity is above what the server
//    says is available (the server still refuses it);
//  * one line per product: choosing a product already on another line merges
//    the quantities into that line (the barcode scanner, in increment mode,
//    adds one unit to the existing line);
//  * the two warehouse pickers can't hold the same warehouse;
//  * "Get Low-Stock Products": loads the server's suggestions
//    (Inventory::TransferReplenishment) into the modal and copies the chosen
//    ones into lines, merging a product already present (keeping the larger
//    quantity).
export default class extends Controller {
  static targets = ["source", "destination", "sourceFixed", "destinationFixed", "rows", "sameWarehouse", "notice",
                    "summarySource", "summaryDestination", "summaryLines", "summaryQuantity", "summaryWarnings",
                    "replenishButton", "modal", "modalBody"]
  static values = { availabilityUrl: String, replenishmentUrl: String, transferId: String, shortLabel: String,
                    noWarnings: String, warningLine: String, loadFailed: String, loading: String, merged: String }

  connect() {
    this.figures = {}
    // Lines added, removed or hidden (line-items#remove) — never the warnings
    // this controller toggles inside a line, which would loop.
    this.observer = new MutationObserver((mutations) => {
      if (mutations.some((m) => m.type === "childList" || m.target.matches?.("[data-stock-transfer-line]"))) this.#scheduleRefresh()
    })
    this.observer.observe(this.rowsTarget, { childList: true, subtree: true, attributes: true, attributeFilter: ["hidden"] })
    this.#syncWarehouses()
    this.#refresh()
  }

  disconnect() {
    this.observer?.disconnect()
    clearTimeout(this.timer)
  }

  warehousesChanged() {
    this.#syncWarehouses()
    this.#refresh()
  }

  rowsChanged(event) {
    const select = event.target.closest("select[data-product-field]")
    if (select) this.#mergeDuplicate(select)
    this.#scheduleRefresh()
  }

  quantityChanged(event) {
    if (event.target.matches("[data-quantity-field]")) this.#render()
  }

  // ── Low-stock suggestions ───────────────────────────────────────────────
  async openReplenishment() {
    const ends = this.#ends()
    if (!ends.source || !ends.destination || ends.source === ends.destination) return
    this.modalTarget.style.display = ""
    await this.#loadSuggestions(ends)
  }

  refreshReplenishment() {
    const ends = this.#ends()
    if (ends.source && ends.destination) this.#loadSuggestions(ends)
  }

  closeReplenishment() {
    if (this.hasModalTarget) this.modalTarget.style.display = "none"
  }

  closeOnBackdrop(event) {
    if (event.target === this.modalTarget) this.closeReplenishment()
  }

  toggleAllSuggestions(event) {
    this.modalBodyTarget.querySelectorAll("[data-replenishment-check]:not(:disabled)")
      .forEach((box) => { box.checked = event.target.checked })
  }

  addSelected() {
    let added = 0
    this.modalBodyTarget.querySelectorAll("[data-replenishment-row]").forEach((row) => {
      const box = row.querySelector("[data-replenishment-check]")
      const qtyInput = row.querySelector("[data-replenishment-quantity]")
      if (!box?.checked || box.disabled) return
      const quantity = Number.parseFloat(qtyInput?.value || "0")
      if (!(quantity > 0)) return
      this.#addOrMerge(JSON.parse(row.dataset.product), quantity)
      added += 1
    })
    this.closeReplenishment()
    if (added) this.#refresh()
  }

  // ── internals ───────────────────────────────────────────────────────────
  async #loadSuggestions(ends) {
    this.modalBodyTarget.innerHTML = `<p class="lsp__empty">${this.#escape(this.loadingValue)}</p>`
    try {
      const url = `${this.replenishmentUrlValue}?source_warehouse_id=${encodeURIComponent(ends.source)}&destination_warehouse_id=${encodeURIComponent(ends.destination)}`
      const res = await fetch(url, { headers: { Accept: "text/html" } })
      if (!res.ok) throw new Error(String(res.status))
      this.modalBodyTarget.innerHTML = await res.text()
    } catch {
      this.modalBodyTarget.innerHTML = `<p class="lsp__note lsp__note--error" role="alert">${this.#escape(this.loadFailedValue)}</p>`
    }
  }

  #ends() {
    const source = this.hasSourceTarget ? this.sourceTarget.value : this.sourceFixedTarget?.dataset.warehouseId
    const destination = this.hasDestinationTarget ? this.destinationTarget.value : this.destinationFixedTarget?.dataset.warehouseId
    return { source: source || "", destination: destination || "" }
  }

  #syncWarehouses() {
    const ends = this.#ends()
    if (this.hasSourceTarget && this.hasDestinationTarget) {
      for (const [select, other] of [ [ this.sourceTarget, ends.destination ], [ this.destinationTarget, ends.source ] ]) {
        Array.from(select.options).forEach((option) => { option.disabled = option.value !== "" && option.value === other })
      }
    }
    const same = ends.source && ends.source === ends.destination
    if (this.hasSameWarehouseTarget) this.sameWarehouseTarget.hidden = !same
    if (this.hasReplenishButtonTarget) this.replenishButtonTarget.disabled = !(ends.source && ends.destination) || same
    if (this.hasSummarySourceTarget) this.summarySourceTarget.textContent = this.#endLabel("source") || "—"
    if (this.hasSummaryDestinationTarget) this.summaryDestinationTarget.textContent = this.#endLabel("destination") || "—"
  }

  #endLabel(side) {
    const select = side === "source" ? (this.hasSourceTarget && this.sourceTarget) : (this.hasDestinationTarget && this.destinationTarget)
    if (select) return select.value ? select.selectedOptions[0]?.textContent.trim() : ""
    const fixed = side === "source" ? this.sourceFixedTarget : this.destinationFixedTarget
    return fixed?.textContent.trim()
  }

  #lines() {
    return Array.from(this.rowsTarget.querySelectorAll("[data-stock-transfer-line]:not([hidden])"))
  }

  #productOf(row) { return row.querySelector("select[data-product-field]")?.value || "" }
  #quantityInput(row) { return row.querySelector("[data-quantity-field]") }
  #quantityOf(row) { return Number.parseFloat(this.#quantityInput(row)?.value || "0") || 0 }

  // A product chosen on a second line: its quantity joins the first line.
  #mergeDuplicate(select) {
    const row = select.closest("[data-stock-transfer-line]")
    const id = select.value
    if (!row || !id) return
    const twin = this.#lines().find((other) => other !== row && this.#productOf(other) === id)
    if (!twin) return
    const qty = this.#quantityInput(twin)
    qty.value = String(this.#quantityOf(twin) + (this.#quantityOf(row) || 0))
    row.querySelector("[data-action~='line-items#remove']")?.click()
    qty.focus()
    this.#notify(this.mergedValue)
  }

  #addOrMerge(product, quantity) {
    const id = String(product.id)
    const existing = this.#lines().find((row) => this.#productOf(row) === id)
    if (existing) {
      const qty = this.#quantityInput(existing)
      qty.value = String(Math.max(this.#quantityOf(existing), quantity))
      return
    }
    let row = this.#lines().find((line) => !this.#productOf(line))
    if (!row) row = this.#appendRow()
    selectProduct(row.querySelector("select[data-product-field]"), product)
    this.#quantityInput(row).value = String(quantity)
  }

  #appendRow() {
    const template = this.element.querySelector('[data-line-items-target="template"]')
    this.rowsTarget.insertAdjacentHTML("beforeend", template.innerHTML.replace(/NEW_INDEX/g, `${Date.now()}${Math.floor(Math.random() * 1000)}`))
    const empty = this.element.querySelector('[data-line-items-target="emptyState"]')
    if (empty) empty.hidden = true
    return this.rowsTarget.lastElementChild
  }

  #scheduleRefresh() {
    clearTimeout(this.timer)
    this.timer = setTimeout(() => this.#refresh(), 200)
  }

  async #refresh() {
    const ends = this.#ends()
    const ids = [...new Set(this.#lines().map((row) => this.#productOf(row)).filter(Boolean))]
    if (!ends.source || ids.length === 0) { this.figures = {}; this.#render(); return }
    const params = new URLSearchParams({ source_warehouse_id: ends.source })
    if (ends.destination && ends.destination !== ends.source) params.append("destination_warehouse_id", ends.destination)
    if (this.transferIdValue) params.append("stock_transfer_id", this.transferIdValue)
    ids.forEach((id) => params.append("product_ids[]", id))
    try {
      const res = await fetch(`${this.availabilityUrlValue}?${params}`, { headers: { Accept: "application/json" } })
      if (!res.ok) throw new Error(String(res.status))
      const data = await res.json()
      this.figures = Object.fromEntries(data.products.map((p) => [ String(p.product_id), p ]))
    } catch {
      this.figures = {}
    }
    this.#render()
  }

  #render() {
    let lines = 0
    let total = 0
    const warnings = []
    this.#lines().forEach((row) => {
      const id = this.#productOf(row)
      const qty = this.#quantityOf(row)
      const f = this.figures[id]
      if (id) { lines += 1; total += qty }
      this.#cell(row, "source_on_hand", f?.source_on_hand)
      this.#cell(row, "source_reserved", f?.source_reserved)
      this.#cell(row, "source_available", f?.source_available)
      this.#cell(row, "destination_on_hand", f?.destination_on_hand)
      this.#cell(row, "destination_incoming", f?.destination_incoming)
      const after = f && f.destination_on_hand != null ? this.#format(Number.parseFloat(f.destination_on_hand) + qty) : null
      this.#cell(row, "after_transfer", after)
      const warning = row.querySelector("[data-cell='warning']")
      const short = f ? qty - Number.parseFloat(f.source_available) : 0
      row.classList.toggle("stf__row--short", short > 0)
      if (warning) {
        warning.hidden = !(short > 0)
        warning.textContent = short > 0 ? this.shortLabelValue.replace("__QTY__", this.#format(short)) : ""
      }
      if (short > 0) {
        const name = row.querySelector("select[data-product-field]")?.selectedOptions[0]?.textContent.trim() || id
        warnings.push(this.warningLineValue.replace("__PRODUCT__", name).replace("__QTY__", this.#format(short)))
      }
    })
    if (this.hasSummaryLinesTarget) this.summaryLinesTarget.textContent = String(lines)
    if (this.hasSummaryQuantityTarget) this.summaryQuantityTarget.textContent = this.#format(total)
    if (this.hasSummaryWarningsTarget) {
      this.summaryWarningsTarget.innerHTML = warnings.length
        ? warnings.map((w) => `<li class="text-danger">${this.#escape(w)}</li>`).join("")
        : `<li class="td-secondary">${this.#escape(this.noWarningsValue)}</li>`
    }
    this.#syncWarehouses()
  }

  #cell(row, name, value) {
    const cell = row.querySelector(`[data-cell='${name}']`)
    if (cell) cell.textContent = value == null || value === "" ? "—" : this.#format(Number.parseFloat(value))
  }

  #format(number) {
    if (!Number.isFinite(number)) return "—"
    return Number.isInteger(number) ? String(number) : String(Number(number.toFixed(3)))
  }

  #notify(message) {
    if (!this.hasNoticeTarget || !message) return
    this.noticeTarget.textContent = message
    this.noticeTarget.hidden = false
    clearTimeout(this.noticeTimer)
    this.noticeTimer = setTimeout(() => { this.noticeTarget.hidden = true }, 4000)
  }

  #escape(text) {
    const el = document.createElement("div")
    el.textContent = text == null ? "" : String(text)
    return el.innerHTML
  }
}
