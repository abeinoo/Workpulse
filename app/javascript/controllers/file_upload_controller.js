import { Controller } from "@hotwired/stimulus"

// Handles drag-and-drop and click-to-browse for single-file CSV upload.
export default class extends Controller {
  static targets = ["input", "label", "dropzone"]

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
    // Transfer dropped file to the hidden input
    const dt = new DataTransfer()
    dt.items.add(file)
    this.inputTarget.files = dt.files
    this.#showName(file.name)
  }

  #showName(name) {
    this.labelTarget.textContent = name
    this.labelTarget.classList.add("file-upload-area__filename--selected")
  }
}
