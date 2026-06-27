import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = [
    "recipientSection",
    "nextDayWrapper",
    "nextDaySection",
    "depositorWrapper",
    "depositorPickerSection"
  ]

  connect() {
    this.#syncAll()
  }

  handoverTypeChanged({ target }) {
    const isCloseDay = target.value === "1"
    this.recipientSectionTarget.hidden = isCloseDay
    this.nextDayWrapperTarget.hidden   = !isCloseDay
    if (this.hasDepositorWrapperTarget) this.depositorWrapperTarget.hidden = !isCloseDay
  }

  nextDayToggleChanged({ target }) {
    this.nextDaySectionTarget.hidden = target.value !== "1"
  }

  depositorTypeChanged({ target }) {
    if (this.hasDepositorPickerSectionTarget) {
      this.depositorPickerSectionTarget.hidden = target.value !== "other"
    }
  }

  validateSubmit(event) {
    this.#clearErrors()
    const errors = this.#checkMinimums()
    this.#checkDepositor(errors)
    if (errors.length > 0) {
      event.preventDefault()
      this.#showErrorBanner(errors)
    }
  }

  #checkDepositor(errors) {
    const typeChecked = this.element.querySelector('input[name="till_handover[self_deposit]"]:checked')
    if (typeChecked?.value !== "1") return

    const depositorTypeChecked = this.element.querySelector('input[name="till_handover[depositor_type]"]:checked')
    if (!depositorTypeChecked) {
      errors.push(this.element.dataset.tillClosingDepositorRequired || "Please select who will be responsible for today's deposit.")
      return
    }

    if (depositorTypeChecked.value === "other") {
      const depositorPicked = this.element.querySelector('input[name="till_handover[depositor_id]"]:checked')
      if (!depositorPicked) {
        errors.push(this.element.dataset.tillClosingDepositorRequired || "Please select who will be responsible for today's deposit.")
      }
    }
  }

  #checkMinimums() {
    const errors = []
    const fields = this.element.querySelectorAll("[data-minimum]")
    fields.forEach(field => {
      const minimum = parseFloat(field.dataset.minimum) || 0
      if (minimum <= 0) return
      const value = parseFloat(field.value) || 0
      if (value < minimum) {
        field.style.outline = "2px solid var(--error, #dc2626)"
        field.style.outlineOffset = "1px"
        const pmName = field.closest("[data-pm-name]")?.dataset.pmName || ""
        const label = field.closest(".form-group")?.querySelector(".form-label")?.textContent?.trim() || ""
        const minFormatted = minimum.toLocaleString(undefined, { minimumFractionDigits: 2, maximumFractionDigits: 2 })
        errors.push(`${pmName} — ${label}: ${minFormatted}`)
      }
    })
    return errors
  }

  #clearErrors() {
    this.element.querySelectorAll("[data-minimum]").forEach(field => {
      field.style.outline = ""
      field.style.outlineOffset = ""
    })
    this.element.querySelector("[data-till-closing-error]")?.remove()
  }

  #showErrorBanner(errors) {
    const title = this.element.dataset.tillClosingErrorTitle || "Cannot submit — amounts below minimum received"
    const banner = document.createElement("div")
    banner.setAttribute("data-till-closing-error", "")
    banner.style.cssText = [
      "background: rgba(220,38,38,0.08)",
      "border: 1.5px solid rgba(220,38,38,0.35)",
      "border-radius: var(--radius-lg)",
      "padding: var(--space-4) var(--space-5)",
      "color: var(--error, #dc2626)",
      "font-size: var(--text-sm)",
      "margin-top: var(--space-3)"
    ].join(";")
    banner.innerHTML = `
      <p style="font-weight:700;margin:0 0 var(--space-2);">${title}</p>
      <ul style="margin:0;padding-inline-start:var(--space-5);">
        ${errors.map(e => `<li>${e}</li>`).join("")}
      </ul>`
    const cta = this.element.querySelector(".emp-dashboard__cta")
    cta ? cta.insertAdjacentElement("beforebegin", banner) : this.element.append(banner)
    banner.scrollIntoView({ behavior: "smooth", block: "nearest" })
  }

  #syncAll() {
    const typeChecked = this.element.querySelector('input[name="till_handover[self_deposit]"]:checked')
    if (typeChecked) {
      const isCloseDay = typeChecked.value === "1"
      if (this.hasRecipientSectionTarget)       this.recipientSectionTarget.hidden  = isCloseDay
      if (this.hasNextDayWrapperTarget)         this.nextDayWrapperTarget.hidden    = !isCloseDay
      if (this.hasDepositorWrapperTarget)       this.depositorWrapperTarget.hidden  = !isCloseDay
    }

    const nextDayChecked = this.element.querySelector('input[name="till_handover[has_next_day]"]:checked')
    if (nextDayChecked && this.hasNextDaySectionTarget) {
      this.nextDaySectionTarget.hidden = nextDayChecked.value !== "1"
    }

    const depositorTypeChecked = this.element.querySelector('input[name="till_handover[depositor_type]"]:checked')
    if (depositorTypeChecked && this.hasDepositorPickerSectionTarget) {
      this.depositorPickerSectionTarget.hidden = depositorTypeChecked.value !== "other"
    }
  }
}
