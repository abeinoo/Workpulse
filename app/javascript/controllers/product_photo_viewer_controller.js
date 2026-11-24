import { Controller } from "@hotwired/stimulus"

// Product Show page photo gallery (read-only; _show_gallery.html.erb).
// Picking a thumbnail shows that photo as the main image; the main image opens
// a full-screen viewer (native <dialog>, like id_photo_viewer_controller) with
// previous / next. Arrow keys move between photos in the reading direction —
// in RTL the "next" photo is to the left. Home / End jump to the first / last.
// A photo that fails to load shows a placeholder instead of a broken image.
export default class extends Controller {
  static targets = ["main", "broken", "thumb", "counter", "dialog", "viewerImage", "viewerCounter"]
  static values = { photos: Array, position: String }

  connect() {
    this.index = 0
    // The main image may have failed before this controller connected.
    if (this.hasMainTarget && this.mainTarget.complete && this.mainTarget.naturalWidth === 0) this.broken()
  }

  select(event) {
    this.show(Number(event.currentTarget.dataset.index))
  }

  // Keyboard on the thumbnail strip: move the selection and the focus together.
  navigate(event) {
    const target = this.targetFor(event.key)
    if (target === null) return

    event.preventDefault()
    this.show(target)
    this.thumbTargets[target]?.focus()
  }

  // Keyboard inside the viewer (Escape is the dialog's own).
  viewerKey(event) {
    const target = this.targetFor(event.key)
    if (target === null) return

    event.preventDefault()
    this.show(target)
  }

  previous() { this.show(this.wrap(this.index - 1)) }
  next()     { this.show(this.wrap(this.index + 1)) }

  open() {
    if (!this.hasDialogTarget || !this.photosValue.length) return

    this.renderViewer()
    this.dialogTarget.showModal()
  }

  close() {
    this.dialogTarget.close()
  }

  backdrop(event) {
    if (event.target === this.dialogTarget) this.close()
  }

  broken() {
    this.mainTarget.hidden = true
    if (this.hasBrokenTarget) this.brokenTarget.hidden = false
  }

  thumbBroken(event) {
    event.currentTarget.closest("button")?.classList.add("is-broken")
  }

  // ── internals ──────────────────────────────────────────────

  show(index) {
    const photo = this.photosValue[index]
    if (!photo) return

    this.index = index
    if (this.hasMainTarget) {
      this.mainTarget.hidden = false
      if (this.hasBrokenTarget) this.brokenTarget.hidden = true
      this.mainTarget.src = photo.url
      this.mainTarget.alt = photo.alt
    }
    this.thumbTargets.forEach((thumb, i) => {
      const selected = i === index
      thumb.classList.toggle("is-selected", selected)
      thumb.setAttribute("aria-pressed", String(selected))
    })
    if (this.hasCounterTarget) this.counterTarget.textContent = this.positionText()
    if (this.hasDialogTarget && this.dialogTarget.open) this.renderViewer()
  }

  renderViewer() {
    const photo = this.photosValue[this.index]
    this.viewerImageTarget.src = photo.url
    this.viewerImageTarget.alt = photo.alt
    if (this.hasViewerCounterTarget) this.viewerCounterTarget.textContent = this.positionText()
  }

  // The photo a key moves to, or null when the key is not a gallery key.
  targetFor(key) {
    const count = this.photosValue.length
    if (count < 2) return null

    const rtl = getComputedStyle(this.element).direction === "rtl"
    switch (key) {
      case "ArrowRight": return this.wrap(this.index + (rtl ? -1 : 1))
      case "ArrowLeft":  return this.wrap(this.index + (rtl ? 1 : -1))
      case "Home":       return 0
      case "End":        return count - 1
      default:           return null
    }
  }

  wrap(index) {
    const count = this.photosValue.length
    return ((index % count) + count) % count
  }

  positionText() {
    return this.positionValue
      .replace("%{index}", this.index + 1)
      .replace("%{count}", this.photosValue.length)
  }
}
