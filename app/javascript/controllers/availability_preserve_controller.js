import { Controller } from "@hotwired/stimulus"

// The availability section is one Turbo Frame: every action re-renders it.
// What the user has typed in OTHER cards and not saved would be lost, so
// before the frame renders it is collected, and put back afterwards:
//   - settings fields (by data-preserve-id), only where the stored value is
//     still the one the user started from (never over someone else's change);
//   - an exclusion checkbox the user changed (the open "Exclude" / "Include
//     again" panel), re-opened only if the card's stored state is unchanged,
//     with the reason typed in it — restored once its panel has loaded.
// Nothing is submitted: the panel just re-opens with the text. The form that
// was submitted is skipped: its own result wins.
export default class extends Controller {
  connect() {
    this.beforeRender = this.#collect.bind(this)
    this.afterRender  = this.#restore.bind(this)
    this.submitStart  = (event) => { this.submitted = event.target }
    this.panelLoad    = this.#fillReasons.bind(this)
    this.typed        = this.#reasonTyped.bind(this)
    this.reasons      = new Map() // card testid => reason still to put back
    this.element.addEventListener("turbo:before-frame-render", this.beforeRender)
    this.element.addEventListener("turbo:frame-render", this.afterRender)
    this.element.addEventListener("turbo:submit-start", this.submitStart)
    this.element.addEventListener("turbo:frame-load", this.panelLoad, true) // capture: the panel frames' own loads
    this.element.addEventListener("input", this.typed)
  }

  disconnect() {
    this.element.removeEventListener("turbo:before-frame-render", this.beforeRender)
    this.element.removeEventListener("turbo:frame-render", this.afterRender)
    this.element.removeEventListener("turbo:submit-start", this.submitStart)
    this.element.removeEventListener("turbo:frame-load", this.panelLoad, true)
    this.element.removeEventListener("input", this.typed)
  }

  #collect(event) {
    // Only the section frame itself (not a card's own lazy panel loading).
    if (event.target.id !== "product-availability") return

    this.fields = []
    this.element.querySelectorAll("input[data-preserve-id]").forEach((field) => {
      if (this.submitted && field.form === this.submitted) return
      const changed = field.type === "checkbox" ? field.checked !== field.defaultChecked : field.value !== field.defaultValue
      if (!changed) return
      this.fields.push({ id: field.dataset.preserveId, value: field.value, checked: field.checked,
                         stored: field.type === "checkbox" ? field.defaultChecked : field.defaultValue })
    })

    const kept = new Map(this.reasons) // reasons whose panel has not loaded again yet
    this.reasons.clear()
    this.panels = []
    this.element.querySelectorAll("[data-availability-exclude-target='checkbox']").forEach((box) => {
      if (box.checked === box.defaultChecked) return
      const card = box.closest("[data-testid^='availability-card-']")
      const reason = card?.querySelector("textarea[name='reason']")
      if (this.submitted && reason?.form === this.submitted) return
      this.panels.push({ card: card?.dataset.testid, stored: box.defaultChecked,
                         reason: reason?.value || kept.get(card?.dataset.testid) || "" })
    })
  }

  #restore(event) {
    if (event.target.id !== "product-availability") return

    ;(this.fields || []).forEach((saved) => {
      const field = this.element.querySelector(`[data-preserve-id="${CSS.escape(saved.id)}"]`)
      if (!field) return
      const stored = field.type === "checkbox" ? field.defaultChecked : field.defaultValue
      if (stored !== saved.stored) return
      if (field.type === "checkbox") field.checked = saved.checked
      else field.value = saved.value
      field.dispatchEvent(new Event("input", { bubbles: true }))
      field.dispatchEvent(new Event("change", { bubbles: true }))
    })

    ;(this.panels || []).forEach((saved) => {
      const card = this.element.querySelector(`[data-testid="${CSS.escape(saved.card)}"]`)
      const box = card?.querySelector("[data-availability-exclude-target='checkbox']")
      if (!box || box.defaultChecked !== saved.stored) return
      box.checked = !saved.stored
      box.dispatchEvent(new Event("change", { bubbles: true })) // re-opens (and loads) the panel
      if (saved.reason) this.reasons.set(saved.card, saved.reason)
    })
    this.#fillReasons()

    this.fields = []
    this.panels = []
    this.submitted = null
  }

  // The exclusion panel is loaded into its own (lazy) frame, possibly more
  // than once: on EVERY load, put a kept reason back into an empty reason box.
  // Kept until the user types in that box or the section is refreshed again
  // (looked up by card each time — never a stale element).
  #fillReasons() {
    this.reasons.forEach((text, testid) => {
      const reason = this.element.querySelector(`[data-testid="${CSS.escape(testid)}"] textarea[name='reason']`)
      if (reason && !reason.value) reason.value = text
    })
  }

  #reasonTyped(event) {
    if (!event.isTrusted || event.target.name !== "reason") return
    const card = event.target.closest("[data-testid^='availability-card-']")
    if (card) this.reasons.delete(card.dataset.testid)
  }
}
