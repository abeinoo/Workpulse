import { Controller } from "@hotwired/stimulus"

// Light / dark theme toggle.
//
// The active theme is a single class (`light` / `dark`) on <html>, applied
// before first paint by the inline bootstrap script in the <head>. This
// controller only flips that class on click, persists the choice to
// localStorage, and keeps the button's pressed state in sync.
//
// Turbo replaces <body> but never <html>, so the chosen theme survives
// navigation automatically. Multiple toggle buttons (sidebar + mobile header)
// stay in sync via a window-level `theme:changed` event.
export default class extends Controller {
  connect() {
    this.onThemeChanged = this.syncPressed.bind(this)
    window.addEventListener("theme:changed", this.onThemeChanged)
    this.syncPressed()
  }

  disconnect() {
    window.removeEventListener("theme:changed", this.onThemeChanged)
  }

  toggle(event) {
    event.preventDefault()

    const root = document.documentElement
    const next = root.classList.contains("dark") ? "light" : "dark"

    // Animate the swap only while toggling (not on load / navigation).
    root.classList.add("theme-transition")
    root.classList.toggle("dark", next === "dark")

    try {
      localStorage.setItem("theme", next)
    } catch (e) {
      /* storage unavailable (private mode) — theme still applies for the session */
    }

    window.clearTimeout(this.transitionTimer)
    this.transitionTimer = window.setTimeout(
      () => root.classList.remove("theme-transition"),
      260
    )

    window.dispatchEvent(new CustomEvent("theme:changed", { detail: { theme: next } }))
  }

  syncPressed() {
    const isDark = document.documentElement.classList.contains("dark")
    this.element.setAttribute("aria-pressed", isDark ? "true" : "false")
  }
}
