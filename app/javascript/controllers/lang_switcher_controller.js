import { Controller } from "@hotwired/stimulus"

// Dropdown language switcher. Reused on the login page and inside the sidebar.
//
// Outline-only behavior:
//   - Click trigger → toggle menu open/closed
//   - Click outside the dropdown → close
//   - Press Escape → close
//   - Click an option → PATCH the configured endpoint, then full page reload
//
// Endpoint is configured on the controller root via `data-lang-switcher-url-value`,
// so the same controller works for authenticated (/preferences/locale) and
// unauthenticated (/locale) contexts.
export default class extends Controller {
  static targets = ["menu", "trigger", "label"]
  static values  = { url: String, current: String }

  connect() {
    this.boundDocClick = this.handleDocClick.bind(this)
    this.boundKeyDown  = this.handleKeyDown.bind(this)
    document.addEventListener("click",   this.boundDocClick)
    document.addEventListener("keydown", this.boundKeyDown)
  }

  disconnect() {
    document.removeEventListener("click",   this.boundDocClick)
    document.removeEventListener("keydown", this.boundKeyDown)
  }

  toggle(event) {
    event.preventDefault()
    event.stopPropagation()
    this.menuTarget.hidden ? this.open() : this.close()
  }

  open() {
    this.menuTarget.hidden = false
    this.element.classList.add("is-open")
    this.triggerTarget.setAttribute("aria-expanded", "true")
  }

  close() {
    this.menuTarget.hidden = true
    this.element.classList.remove("is-open")
    this.triggerTarget.setAttribute("aria-expanded", "false")
  }

  select(event) {
    event.preventDefault()
    const locale = event.currentTarget.dataset.locale
    if (!locale || locale === this.currentValue) {
      this.close()
      return
    }

    const csrfToken = document.querySelector('meta[name="csrf-token"]')?.content
    fetch(this.urlValue, {
      method: "PATCH",
      headers: {
        "Content-Type": "application/json",
        "X-CSRF-Token": csrfToken,
        "Accept":       "application/json",
      },
      body: JSON.stringify({ locale }),
    })
      .catch(() => {})
      .finally(() => { window.location.reload() })
  }

  handleDocClick(event) {
    if (!this.element.contains(event.target)) this.close()
  }

  handleKeyDown(event) {
    if (event.key === "Escape") this.close()
  }
}
