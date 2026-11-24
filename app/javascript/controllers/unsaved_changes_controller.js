import { Controller } from "@hotwired/stimulus"

// The product Edit page's one Save: shows "unsaved changes" beside it as soon
// as any field of the product form changes — including the fields laid out
// outside the <form> element that join it through the form attribute
// (gallery, availability cards, notes) and added / removed
// barcode rows. Turbo disables the Save button while the request runs
// (data-turbo-submits-with), so the submission can't be sent twice.
export default class extends Controller {
  static targets = ["badge"]
  static values = { form: String }

  connect() {
    this.onChange = (event) => { if (this.#belongsToForm(event.target)) this.#mark() }
    this.onClick = (event) => {
      if (event.target.closest?.("[data-action*='line-items#add'], [data-action*='line-items#remove']")) this.#mark()
    }
    document.addEventListener("input", this.onChange)
    document.addEventListener("change", this.onChange)
    this.element.addEventListener("click", this.onClick)
  }

  disconnect() {
    document.removeEventListener("input", this.onChange)
    document.removeEventListener("change", this.onChange)
    this.element.removeEventListener("click", this.onClick)
  }

  #belongsToForm(el) {
    return el?.form?.id === this.formValue || el?.getAttribute?.("form") === this.formValue
  }

  #mark() {
    if (this.hasBadgeTarget) this.badgeTarget.hidden = false
  }
}
