import { Controller } from "@hotwired/stimulus"

// Opens the once-per-day birthday dialog with a short confetti burst.
// Opening it POSTs an acknowledgement so reloading the dashboard the same
// business day doesn't show it again. Confetti is skipped for users who
// prefer reduced motion.
export default class extends Controller {
  static targets = ["dialog", "confetti"]
  static values = { url: String }

  static PIECES = 80
  static DURATION_MS = 5200

  connect() {
    if (this.dialogTarget.open) return

    this.dialogTarget.showModal()
    this.#acknowledge()
    if (!window.matchMedia("(prefers-reduced-motion: reduce)").matches) this.#burst()
  }

  disconnect() {
    clearTimeout(this._cleanup)
    if (this.dialogTarget.open) this.dialogTarget.close()
  }

  close() {
    this.dialogTarget.close()
  }

  // Close when clicking the backdrop (the <dialog> itself, not its content)
  backdropClose(event) {
    if (event.target === this.dialogTarget) this.close()
  }

  #acknowledge() {
    const token = document.querySelector('meta[name="csrf-token"]')?.content
    fetch(this.urlValue, {
      method: "POST",
      headers: { "X-CSRF-Token": token, "Accept": "application/json" },
      credentials: "same-origin",
      keepalive: true
    }).catch(() => {})
  }

  #burst() {
    const { PIECES, DURATION_MS } = this.constructor
    const fragment = document.createDocumentFragment()

    for (let i = 0; i < PIECES; i++) {
      const piece = document.createElement("span")
      piece.className = "birthday-confetti__piece"
      piece.style.setProperty("--x", `${Math.random() * 100}vw`)
      piece.style.setProperty("--drift", `${(Math.random() - 0.5) * 30}vw`)
      piece.style.setProperty("--spin", `${360 + Math.random() * 720}deg`)
      piece.style.setProperty("--delay", `${Math.random() * 900}ms`)
      piece.style.setProperty("--fall", `${2600 + Math.random() * 1800}ms`)
      fragment.appendChild(piece)
    }

    this.confettiTarget.appendChild(fragment)
    this._cleanup = setTimeout(() => this.confettiTarget.replaceChildren(), DURATION_MS)
  }
}
