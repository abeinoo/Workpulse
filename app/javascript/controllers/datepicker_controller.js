import { Controller } from "@hotwired/stimulus"
import flatpickr from "flatpickr"

// Visual calendar / time picker built on Flatpickr.
//
// Usage:
//   <input data-controller="datepicker" data-datepicker-mode-value="date">
//   modes: "date" (default) | "time" | "datetime"
//
// The whole field opens the picker on click (clickOpens), values stay in the
// HTML-native serialization the Rails forms expect:
//   date     → "Y-m-d"
//   time     → "H:i"
//   datetime → "Y-m-d H:i"
// altInput shows a friendlier, locale-aware label while the real input keeps
// the machine value. Native typing remains possible as a fallback.
export default class extends Controller {
  static values = { mode: { type: String, default: "date" } }

  connect() {
    const opts = {
      allowInput: true,
      clickOpens: true,
      altInput:   true,
      time_24hr:  true,
      locale:     this.#locale()
    }

    // Preserve any native min/max bounds (e.g. the end-assignment form sets a
    // min effective date) so Flatpickr enforces the same constraints.
    if (this.element.min) opts.minDate = this.element.min
    if (this.element.max) opts.maxDate = this.element.max

    switch (this.modeValue) {
      case "time":
        opts.enableTime = true
        opts.noCalendar = true
        opts.dateFormat = "H:i"
        opts.altFormat  = "H:i"
        break
      case "datetime":
        opts.enableTime = true
        opts.dateFormat = "Y-m-d H:i"
        opts.altFormat  = "M j, Y H:i"
        break
      default: // date
        opts.dateFormat = "Y-m-d"
        opts.altFormat  = "M j, Y"
    }

    this.fp = flatpickr(this.element, opts)

    // With altInput, Flatpickr hides the real <input>. A `required` attribute on
    // a hidden input makes the browser throw "an invalid form control is not
    // focusable" and silently block submit — so move validation to the visible
    // alt input instead. Server-side validation still backs this up.
    if (this.fp.altInput && this.element.required) {
      this.element.required = false
      this.fp.altInput.required = true
    }
  }

  disconnect() {
    if (this.fp) {
      this.fp.destroy()
      this.fp = null
    }
  }

  // Flatpickr ships locales as side-effect modules. We lazily attempt Arabic
  // only when the page is Arabic; failure (e.g. CDN miss) silently falls back
  // to the default English locale so the picker still works.
  #locale() {
    const lang = (document.documentElement.lang || "en").toLowerCase()
    if (lang.startsWith("ar")) {
      import("flatpickr/ar")
        .then(mod => { if (this.fp) this.fp.set("locale", mod.Arabic || mod.default) })
        .catch(() => {})
    }
    return "default"
  }
}
