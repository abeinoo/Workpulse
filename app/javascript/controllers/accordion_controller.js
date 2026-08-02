import { Controller } from "@hotwired/stimulus"

// Top-level page-section accordion (Daily Reconciliation show page: Audit
// Log, Sales Verification, Sales Verification Summary, Cash Reconciliation,
// Bank Deposits, POS Transactions). Distinct from the existing, simpler
// `collapsible` controller used for smaller disclosures nested WITHIN these
// sections (per-employee breakdowns, per-payment-method transaction lists) —
// this one additionally persists open/closed state to localStorage (keyed by
// section, not by DR, so the preference carries across every DR page) and
// animates height via the CSS grid-template-rows trick (see
// .recon-accordion__panel in application.css) rather than toggling `hidden`,
// since `display:none` can't be transitioned.
export default class extends Controller {
  static targets = ["trigger", "content", "icon"]
  static values  = { key: String, open: { type: Boolean, default: false } }

  connect() {
    const stored = this.#readStoredState()
    if (stored !== null) this.openValue = stored
    this.#apply(this.openValue)
  }

  toggle(event) {
    event?.preventDefault?.()
    this.openValue = !this.openValue
    this.#apply(this.openValue)
    this.#writeStoredState(this.openValue)
  }

  #apply(open) {
    this.contentTarget.classList.toggle("recon-accordion__panel--open", open)
    this.triggerTargets.forEach(el => el.setAttribute("aria-expanded", open ? "true" : "false"))
    this.iconTargets.forEach(el => { el.textContent = open ? "▼" : "▶" })
  }

  get #storageKey() {
    return `dr_accordion:${this.keyValue}`
  }

  // localStorage can throw (Safari private mode, disabled storage, etc.) —
  // never let a persistence failure break the accordion itself.
  #readStoredState() {
    try {
      const raw = window.localStorage.getItem(this.#storageKey)
      return raw === null ? null : raw === "1"
    } catch {
      return null
    }
  }

  #writeStoredState(open) {
    try {
      window.localStorage.setItem(this.#storageKey, open ? "1" : "0")
    } catch {
      /* ignore — state just won't persist this session */
    }
  }
}
