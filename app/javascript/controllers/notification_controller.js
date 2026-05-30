import { Controller } from "@hotwired/stimulus"

// Drives the notifications list and the header bell dropdown.
//
// On the notifications page each item carries `data-mark-read-url`; clicking
// the check button PATCHes that URL and visually marks the row as read without
// a full reload. The header bell can use `toggle` to open the preview dropdown.
export default class extends Controller {
  static targets = ["menu", "badge"]

  // ── Header dropdown ───────────────────────────────────────────────────────
  connect() {
    if (this.hasMenuTarget) {
      this.boundClose = this.closeOnOutside.bind(this)
      document.addEventListener("click", this.boundClose)
    }
  }

  disconnect() {
    if (this.boundClose) document.removeEventListener("click", this.boundClose)
  }

  toggle(event) {
    event.preventDefault()
    event.stopPropagation()
    if (this.hasMenuTarget) this.menuTarget.hidden = !this.menuTarget.hidden
  }

  closeOnOutside(event) {
    if (this.hasMenuTarget && !this.element.contains(event.target)) {
      this.menuTarget.hidden = true
    }
  }

  // ── Mark a single notification read ───────────────────────────────────────
  markRead(event) {
    event.preventDefault()
    const item = event.currentTarget.closest("[data-mark-read-url]")
    if (!item) return

    const url = item.dataset.markReadUrl
    const csrf = document.querySelector('meta[name="csrf-token"]')?.content

    fetch(url, {
      method: "PATCH",
      headers: { "X-CSRF-Token": csrf, "Accept": "application/json" },
    })
      .then((res) => {
        if (!res.ok) return
        item.classList.remove("notif-item--unread")
        const btn = item.querySelector(".notif-item__read-btn")
        if (btn) btn.remove()
        this.decrementBadge()
      })
      .catch(() => {})
  }

  decrementBadge() {
    document.querySelectorAll(".notif-badge").forEach((badge) => {
      const current = parseInt(badge.textContent, 10)
      if (Number.isNaN(current)) return
      const next = current - 1
      if (next <= 0) {
        badge.remove()
      } else {
        badge.textContent = next > 99 ? "99+" : String(next)
      }
    })
  }
}
