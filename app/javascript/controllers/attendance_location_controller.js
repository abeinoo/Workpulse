import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["lat", "lng", "submitBtn", "error"]
  static values  = { required: { type: Boolean, default: false } }

  #submitting = false

  capture(event) {
    // requestSubmit() re-fires the submit event — let it through so Turbo can process it
    if (this.#submitting) return

    event.preventDefault()

    if (!navigator.geolocation) {
      if (this.requiredValue) {
        this.#showError("Geolocation is not supported by your browser.")
        return
      }
      this.#submit()
      return
    }

    this.#setLoading(true)

    navigator.geolocation.getCurrentPosition(
      ({ coords }) => {
        if (this.hasLatTarget) this.latTarget.value = coords.latitude
        if (this.hasLngTarget) this.lngTarget.value = coords.longitude
        this.#submit()
      },
      (err) => {
        this.#setLoading(false)
        if (err.code === err.PERMISSION_DENIED && this.requiredValue) {
          const msg = window.isSecureContext === false
            ? "Location requires a secure (HTTPS) connection. Please contact your administrator."
            : "Location access denied. Go to your browser or phone settings, enable location for this site, then try again."
          this.#showError(msg)
        } else {
          // Timeout / position unavailable — submit without coordinates and let the server decide
          this.#submit()
        }
      },
      { timeout: 10_000, maximumAge: 0, enableHighAccuracy: true }
    )
  }

  #submit() {
    this.#submitting = true
    this.element.requestSubmit()
  }

  // ── Private ──────────────────────────────────────────────────────────────

  #setLoading(loading) {
    if (this.hasSubmitBtnTarget) {
      this.submitBtnTarget.disabled = loading
      this.submitBtnTarget.dataset.originalText ||= this.submitBtnTarget.textContent.trim()
      if (loading) {
        this.submitBtnTarget.textContent = "Getting location…"
      } else {
        this.submitBtnTarget.textContent = this.submitBtnTarget.dataset.originalText
      }
    }
    if (this.hasErrorTarget) this.errorTarget.hidden = true
  }

  #showError(message) {
    if (this.hasErrorTarget) {
      this.errorTarget.textContent = message
      this.errorTarget.hidden = false
    }
    if (this.hasSubmitBtnTarget) {
      this.submitBtnTarget.disabled = false
      this.submitBtnTarget.textContent = this.submitBtnTarget.dataset.originalText || "Check In"
    }
  }
}
