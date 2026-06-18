import { Controller } from "@hotwired/stimulus"

// Cascades the Expense Type dropdown based on the selected Expense Category.
// On category change: fetches types for that category and repopulates the type select.
// On initial connect (edit form): preserves the already-selected type id.
// When no category is selected: type select is cleared and disabled.
export default class extends Controller {
  static targets = ["categorySelect", "typeSelect"]
  static values = {
    url:              String,
    placeholder:      String,
    initialTypeId:    { type: String, default: "" },
    // Set to false on filter bars where no-category means "show all", not "disabled".
    disableWhenEmpty: { type: Boolean, default: true }
  }

  connect() {
    this.#refresh(this.initialTypeIdValue)
  }

  categoryChanged() {
    this.#refresh(null)
  }

  // ── private ──────────────────────────────────────────────────────────────

  #refresh(preserveTypeId) {
    const categoryId = this.categorySelectTarget.value
    const typeSelect = this.typeSelectTarget

    if (!categoryId) {
      if (this.disableWhenEmptyValue) {
        typeSelect.innerHTML = `<option value="">${this.placeholderValue}</option>`
        typeSelect.disabled = true
      } else {
        // Filter bar: re-fetch all types when category is cleared
        this.#fetchTypes(null, preserveTypeId)
      }
      return
    }

    typeSelect.disabled = false
    this.#fetchTypes(categoryId, preserveTypeId)
  }

  #fetchTypes(categoryId, preserveTypeId) {
    const typeSelect = this.typeSelectTarget
    const url = categoryId
      ? `${this.urlValue}?category_id=${encodeURIComponent(categoryId)}`
      : this.urlValue

    fetch(url, {
      headers: { "X-Requested-With": "XMLHttpRequest", Accept: "application/json" },
      credentials: "same-origin"
    })
      .then(r => r.json())
      .then(types => {
        typeSelect.innerHTML = `<option value="">${this.placeholderValue}</option>`
        types.forEach(({ id, name }) => {
          const opt = document.createElement("option")
          opt.value = id
          opt.textContent = name
          if (preserveTypeId && String(id) === String(preserveTypeId)) opt.selected = true
          typeSelect.appendChild(opt)
        })
        typeSelect.disabled = false
      })
  }
}
