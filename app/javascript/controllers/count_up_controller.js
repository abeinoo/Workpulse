import { Controller } from "@hotwired/stimulus"

// Animates a KPI value counting up from 0 on first paint. The server-rendered
// text (already formatted via format_currency/number_to_percentage) is kept
// as the exact final frame — this only animates the raw numeric magnitude in
// between, it never reformats or recalculates the figure itself.
export default class extends Controller {
  static values = { target: Number }

  connect() {
    const finalText = this.element.textContent

    if (window.matchMedia("(prefers-reduced-motion: reduce)").matches || !Number.isFinite(this.targetValue)) {
      return
    }

    const locale = document.documentElement.getAttribute("dir") === "rtl" ? "ar" : "en"
    const duration = 700
    const start = performance.now()

    const step = (now) => {
      const progress = Math.min((now - start) / duration, 1)
      const eased = 1 - Math.pow(1 - progress, 3)
      this.element.textContent = Math.round(this.targetValue * eased).toLocaleString(locale)

      if (progress < 1) {
        requestAnimationFrame(step)
      } else {
        this.element.textContent = finalText
      }
    }

    this.element.textContent = "0"
    requestAnimationFrame(step)
  }
}
