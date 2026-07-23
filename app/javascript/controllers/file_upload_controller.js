import { Controller } from "@hotwired/stimulus"

// Handles drag-and-drop, click-to-browse, and submit loading state for bank statement file upload (CSV/Excel).
export default class extends Controller {
  static targets = ["input", "label", "dropzone", "submitBtn", "progress"]

  connect() {
    // Reset loading state if the page was restored from Turbo cache after a failed upload
    this.element.addEventListener("turbo:submit-end", this.#onSubmitEnd)
  }

  disconnect() {
    this.element.removeEventListener("turbo:submit-end", this.#onSubmitEnd)
  }

  pick(event) {
    const file = event.target.files[0]
    if (file) this.#showName(file.name)
  }

  dragover(event) {
    event.preventDefault()
    this.dropzoneTarget.classList.add("file-upload-area--active")
  }

  dragleave() {
    this.dropzoneTarget.classList.remove("file-upload-area--active")
  }

  drop(event) {
    event.preventDefault()
    this.dropzoneTarget.classList.remove("file-upload-area--active")
    const file = event.dataTransfer?.files[0]
    if (!file) return
    const dt = new DataTransfer()
    dt.items.add(file)
    this.inputTarget.files = dt.files
    this.#showName(file.name)
  }

  submit() {
    this.#setLoading(true)
  }

  // ── Private ──────────────────────────────────────────────────────────────

  #onSubmitEnd = (event) => {
    // Restore button if Turbo re-rendered the same page (validation failure)
    if (!event.detail?.success) this.#setLoading(false)
  }

  #setLoading(loading) {
    if (this.hasSubmitBtnTarget) {
      this.submitBtnTarget.disabled = loading
      if (loading) {
        this.submitBtnTarget.dataset.originalText ||= this.submitBtnTarget.value || this.submitBtnTarget.textContent
        this.submitBtnTarget.value = this.submitBtnTarget.dataset.uploadingText || "Uploading…"
      } else {
        if (this.submitBtnTarget.dataset.originalText) {
          this.submitBtnTarget.value = this.submitBtnTarget.dataset.originalText
        }
      }
    }
    if (this.hasProgressTarget) {
      this.progressTarget.hidden = !loading
    }
  }

  #showName(name) {
    this.labelTarget.textContent = name
    this.labelTarget.classList.add("file-upload-area__filename--selected")
  }
}
