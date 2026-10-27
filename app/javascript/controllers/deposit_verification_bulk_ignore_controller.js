import { Controller } from "@hotwired/stimulus"

// "تجاهل المحدد" on Deposit Verification's bank-transaction tabs.
//
//   1. Checkbox selection over the CURRENT page only. Only rows the server
//      marked eligible (not linked to a deposit) have an enabled checkbox; the
//      header checkbox toggles exactly those, with an indeterminate state for
//      a partial selection.
//   2. Once every eligible row on the page is ticked and more exist on other
//      pages, an explicit "select all N matching these filters" option
//      appears. Choosing it switches to all-matching mode: the server
//      re-resolves the set from the posted filters and refuses if its count
//      is no longer N. Unticking any row leaves that mode.
//   3. A confirmation modal with the count, the consequences and a required
//      reason; one POST to bulk_ignore. The server re-checks everything under
//      lock and ignores all or nothing.
//
// Selection always starts empty on connect, so a page/filter change (a new
// page load) or a Turbo-cached snapshot never carries stale ids.
export default class extends Controller {
  static targets = [
    "actionBar", "countBadge", "ignoreBtn", "selectMatchingBtn", "matchingNote", "hint",
    "modal", "modalBody", "ids", "reason", "confirmBtn",
  ]

  static values = { modalBody: String, matchingTotal: Number }

  connect() {
    this.allMatching = false
    this.rowBoxes.forEach((b) => { b.checked = false })
    if (this.masterBox) this.masterBox.checked = false
    this._sync()
    this._onKeydown = this._handleKeydown.bind(this)
    document.addEventListener("keydown", this._onKeydown)
  }

  disconnect() {
    document.removeEventListener("keydown", this._onKeydown)
  }

  // ── Selection ────────────────────────────────────────────────────────────

  get rowBoxes() {
    return Array.from(this.element.querySelectorAll(".dv-bulk-check-row:not([disabled])"))
  }

  get checkedBoxes() {
    return this.rowBoxes.filter((b) => b.checked)
  }

  get masterBox() {
    return this.element.querySelector(".dv-bulk-check-all")
  }

  get selectedCount() {
    return this.allMatching ? this.matchingTotalValue : this.checkedBoxes.length
  }

  toggleAll(event) {
    const checked = event.target.checked
    this.allMatching = false
    this.rowBoxes.forEach((b) => { b.checked = checked })
    this._sync()
  }

  rowChanged() {
    this.allMatching = false
    this._sync()
  }

  selectAllMatching() {
    this.rowBoxes.forEach((b) => { b.checked = true })
    this.allMatching = true
    this._sync()
  }

  clear() {
    this.allMatching = false
    this.rowBoxes.forEach((b) => { b.checked = false })
    this._sync()
  }

  _sync() {
    const all       = this.rowBoxes
    const onPage    = this.checkedBoxes.length
    const pageFull  = all.length > 0 && onPage === all.length

    if (this.masterBox) {
      this.masterBox.checked       = pageFull
      this.masterBox.indeterminate = onPage > 0 && onPage < all.length
      this.masterBox.disabled      = all.length === 0
    }
    if (this.hasActionBarTarget) this.actionBarTarget.style.display = onPage > 0 ? "" : "none"
    if (this.hasCountBadgeTarget) this.countBadgeTarget.textContent = this.selectedCount
    if (this.hasIgnoreBtnTarget) this.ignoreBtnTarget.disabled = onPage === 0
    if (this.hasSelectMatchingBtnTarget) {
      this.selectMatchingBtnTarget.style.display = pageFull && !this.allMatching ? "" : "none"
    }
    if (this.hasMatchingNoteTarget) this.matchingNoteTarget.style.display = this.allMatching ? "" : "none"
    if (this.hasHintTarget) this.hintTarget.style.display = this.allMatching ? "none" : ""
  }

  // ── Confirmation modal ───────────────────────────────────────────────────

  openModal() {
    if (this.checkedBoxes.length === 0) return // never post an empty selection

    if (this.hasIdsTarget) {
      this.idsTarget.innerHTML = this.allMatching
        ? `<input type="hidden" name="selection" value="all_matching">` +
          `<input type="hidden" name="expected_count" value="${this.matchingTotalValue}">`
        : this.checkedBoxes
          .map((b) => `<input type="hidden" name="transaction_ids[]" value="${encodeURIComponent(b.value)}">`)
          .join("")
    }
    if (this.hasModalBodyTarget) {
      this.modalBodyTarget.textContent = this.modalBodyValue.replace("%{count}", this.selectedCount)
    }
    this.reasonChanged()
    if (this.hasModalTarget) {
      this.modalTarget.style.display = ""
      requestAnimationFrame(() => this.reasonTarget?.focus())
    }
  }

  reasonChanged() {
    if (this.hasConfirmBtnTarget) this.confirmBtnTarget.disabled = !this._reasonPresent()
  }

  closeModal() {
    if (this.hasModalTarget) this.modalTarget.style.display = "none"
    if (this.hasIgnoreBtnTarget) this.ignoreBtnTarget.focus()
  }

  overlayClick(event) {
    if (event.target === this.modalTarget) this.closeModal()
  }

  // Guards against an empty selection, a blank reason, and a double submit
  // while the POST is in flight.
  submit(event) {
    if (this.checkedBoxes.length === 0 || !this._reasonPresent()) {
      event.preventDefault()
      return
    }
    if (this.hasConfirmBtnTarget) this.confirmBtnTarget.disabled = true
  }

  _reasonPresent() {
    return this.hasReasonTarget && this.reasonTarget.value.trim().length > 0
  }

  _handleKeydown(event) {
    if (!this.hasModalTarget || this.modalTarget.style.display === "none") return
    if (event.key === "Escape") this.closeModal()
  }
}
