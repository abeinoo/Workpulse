import { Controller } from "@hotwired/stimulus"
import { productThumbnail } from "lib/product_thumbnail"
import { ensureProductOption } from "lib/product_option"

// The searchable product picker (ProductThumbnailHelper#product_combobox): an
// ARIA combobox over a server search (Inventory::ProductSearchesController —
// name, SKU or barcode, scoped by the picker's kind), each result with its
// thumbnail, name and SKU / barcode. The form still submits a real (hidden)
// <select> holding only the chosen products' <option>s, so every existing
// listener on it (change events, data-* attributes) works unchanged and the
// catalogue is never loaded into the page.
//
// Keyboard: ↓/↑ move, Enter chooses, Escape closes (keeping the selection),
// Tab leaves. A click outside closes without losing the selection. Searches
// are debounced and cached per query (shared by every picker on the page).
const cache = new Map()

export default class extends Controller {
  static targets = ["select", "input", "listbox", "thumb", "clear"]
  static values  = { url: String, kind: String, loading: String, empty: String, clearable: Boolean }

  connect() {
    this.results = []
    this.active  = -1
    this._onSelectChange = () => this._syncDisplay()
    this._onOutside = (event) => { if (!this.element.contains(event.target)) this.close() }
    this._onViewport = () => this._position()
    this.selectTarget.addEventListener("change", this._onSelectChange)
    // A value set by code without a user change (Low Stock picker, item editor,
    // a reverted duplicate): refresh the display only.
    this.selectTarget.addEventListener("pcombo:refresh", this._onSelectChange)
    document.addEventListener("mousedown", this._onOutside)
    this._syncDisplay()
  }

  disconnect() {
    this.selectTarget.removeEventListener("change", this._onSelectChange)
    this.selectTarget.removeEventListener("pcombo:refresh", this._onSelectChange)
    document.removeEventListener("mousedown", this._onOutside)
    this._unbindViewport()
    clearTimeout(this._timer)
  }

  open() {
    if (!this.listboxTarget.hidden) return
    this.listboxTarget.hidden = false
    this.inputTarget.setAttribute("aria-expanded", "true")
    this._bindViewport()
    this._position()
    this._fetch(this._query())
  }

  close() {
    if (this.listboxTarget.hidden) return
    this.listboxTarget.hidden = true
    this.inputTarget.setAttribute("aria-expanded", "false")
    this.inputTarget.removeAttribute("aria-activedescendant")
    this._unbindViewport()
    this._syncDisplay() // an abandoned search never replaces the selection
  }

  search() {
    if (this.listboxTarget.hidden) this.open()
    clearTimeout(this._timer)
    this._timer = setTimeout(() => this._fetch(this._query()), 200)
  }

  keydown(event) {
    switch (event.key) {
      case "ArrowDown":
        event.preventDefault()
        if (this.listboxTarget.hidden) return this.open()
        return this._move(1)
      case "ArrowUp":
        event.preventDefault()
        return this._move(-1)
      case "Enter":
        if (this.listboxTarget.hidden) return
        event.preventDefault() // never submits the form from the picker
        if (this.results[this.active]) this._choose(this.results[this.active])
        return
      case "Escape":
        if (!this.listboxTarget.hidden) { event.preventDefault(); event.stopPropagation(); this.close() }
        return
      case "Tab":
        return this.close()
    }
  }

  clear() {
    this.selectTarget.value = ""
    this.selectTarget.dispatchEvent(new Event("change", { bubbles: true }))
    this.inputTarget.value = ""
    this.inputTarget.focus()
  }

  // ── internals ──────────────────────────────────────────────────────────

  _query() {
    const selected = this._selectedOption()
    const text = this.inputTarget.value.trim()
    return selected && text === this._label(selected) ? "" : text
  }

  async _fetch(query) {
    const key = `${this.urlValue}|${this.kindValue}|${query.toLowerCase()}`
    this._status(this.loadingValue)
    if (!cache.has(key)) {
      const url = `${this.urlValue}?kind=${encodeURIComponent(this.kindValue)}&q=${encodeURIComponent(query)}`
      cache.set(key, fetch(url, { headers: { Accept: "application/json" } })
        .then((res) => (res.ok ? res.json() : []))
        .catch(() => { cache.delete(key); return [] }))
    }
    const results = await cache.get(key)
    if (query !== this._query() || this.listboxTarget.hidden) return // a newer search took over
    this._render(results, query)
  }

  _render(results, query) {
    this.results = results
    this.active  = results.findIndex((p) => String(p.id) === this.selectTarget.value)
    this.listboxTarget.innerHTML = ""
    if (results.length === 0) return this._status(this.emptyValue.replace("%{query}", query))

    results.forEach((product, index) => {
      const li = document.createElement("li")
      li.id = `${this.listboxTarget.id}-${index}`
      li.className = "pcombo__option"
      li.setAttribute("role", "option")
      li.setAttribute("aria-selected", String(String(product.id) === this.selectTarget.value))
      li.appendChild(productThumbnail(product.thumb, "sm"))
      const text = document.createElement("span")
      text.className = "pcombo__text"
      text.innerHTML = `<span class="pcombo__name">${highlight(product.name, query)}</span>` +
        `<span class="pcombo__meta" dir="ltr">${highlight([ product.sku, product.barcode ].filter(Boolean).join(" · "), query)}</span>`
      li.appendChild(text)
      li.addEventListener("mousedown", (event) => { event.preventDefault(); this._choose(product) })
      li.addEventListener("mousemove", () => this._activate(index))
      this.listboxTarget.appendChild(li)
    })
    this._activate(Math.max(this.active, 0))
    this._position()
  }

  _status(text) {
    this.listboxTarget.innerHTML = ""
    const li = document.createElement("li")
    li.className = "pcombo__status"
    li.setAttribute("role", "presentation")
    li.textContent = text
    this.listboxTarget.appendChild(li)
  }

  _move(step) {
    if (this.results.length === 0) return
    this._activate((this.active + step + this.results.length) % this.results.length)
  }

  _activate(index) {
    this.active = index
    Array.from(this.listboxTarget.querySelectorAll(".pcombo__option")).forEach((li, i) => {
      li.classList.toggle("is-active", i === index)
      if (i === index) {
        this.inputTarget.setAttribute("aria-activedescendant", li.id)
        li.scrollIntoView({ block: "nearest" })
      }
    })
  }

  _choose(product) {
    ensureProductOption(this.selectTarget, product)
    this.selectTarget.value = String(product.id)
    this.listboxTarget.hidden = true
    this.inputTarget.setAttribute("aria-expanded", "false")
    this._unbindViewport()
    this.selectTarget.dispatchEvent(new Event("change", { bubbles: true })) // → _syncDisplay + the line's listeners
  }

  _selectedOption() {
    const option = this.selectTarget.selectedOptions[0]
    return option && option.value ? option : null
  }

  _label(option) {
    return option.dataset.name || option.textContent
  }

  _syncDisplay() {
    const option = this._selectedOption()
    this.inputTarget.value = option ? this._label(option) : ""
    this.thumbTarget.replaceChildren(...(option ? [ productThumbnail(option.dataset.thumb, "sm") ] : []))
    this.thumbTarget.hidden = !option
    if (this.hasClearTarget) this.clearTarget.hidden = !option || !this.clearableValue
  }

  // Fixed to the viewport, above modals and sticky bars, flipping upward when
  // there is no room below — never clipped by a scrolling table or a dialog.
  _position() {
    if (this.listboxTarget.hidden) return
    const rect  = this.inputTarget.getBoundingClientRect()
    const below = window.innerHeight - rect.bottom - 8
    const above = rect.top - 8
    const want  = Math.min(this.listboxTarget.scrollHeight || 320, 320)
    const up    = below < want && above > below
    const style = this.listboxTarget.style
    style.left      = `${rect.left}px`
    style.width     = `${Math.max(rect.width, 280)}px`
    style.maxHeight = `${Math.max(Math.min(320, up ? above : below), 120)}px`
    style.top       = up ? "auto" : `${rect.bottom + 2}px`
    style.bottom    = up ? `${window.innerHeight - rect.top + 2}px` : "auto"
  }

  _bindViewport() {
    window.addEventListener("resize", this._onViewport)
    window.addEventListener("scroll", this._onViewport, true)
  }

  _unbindViewport() {
    window.removeEventListener("resize", this._onViewport)
    window.removeEventListener("scroll", this._onViewport, true)
  }
}

function escapeHtml(text) {
  return String(text).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c])
}

function highlight(text, query) {
  if (!text) return ""
  const i = query ? text.toLowerCase().indexOf(query.toLowerCase()) : -1
  if (i < 0) return escapeHtml(text)
  return escapeHtml(text.slice(0, i)) + `<mark>${escapeHtml(text.slice(i, i + query.length))}</mark>` +
    escapeHtml(text.slice(i + query.length))
}
