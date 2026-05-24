import { Controller } from "@hotwired/stimulus"

// Handles image/document upload fields with live preview and remove support.
//
// Targets:
//   input        — the <input type="file"> element
//   img          — <img> shown when a file is attached (image content types)
//   placeholder  — element shown when no file is attached
//   removeBtn    — button that purges the current attachment
//   removeFlag   — hidden field sent to the server to trigger purge
//   filename     — element that shows the selected filename for non-image files
//
// Usage:
//   <div data-controller="image-upload">
//     <img data-image-upload-target="img" hidden>
//     <div data-image-upload-target="placeholder">...</div>
//     <input type="file" data-image-upload-target="input"
//            data-action="change->image-upload#change">
//     <button data-image-upload-target="removeBtn"
//             data-action="image-upload#remove" hidden>Remove</button>
//     <input type="hidden" value="0" data-image-upload-target="removeFlag">
//   </div>
export default class extends Controller {
  static targets = ["input", "img", "placeholder", "removeBtn", "removeFlag", "filename"]

  change() {
    const file = this.inputTarget.files[0]
    if (!file) return

    // Selecting a new file cancels any pending removal.
    if (this.hasRemoveFlagTarget) this.removeFlagTarget.value = "0"
    if (this.hasRemoveBtnTarget) this.removeBtnTarget.hidden = false

    if (file.type.startsWith("image/")) {
      const reader = new FileReader()
      reader.onload = ({ target: { result } }) => {
        if (this.hasImgTarget) {
          this.imgTarget.src = result
          this.imgTarget.hidden = false
        }
        if (this.hasPlaceholderTarget) this.placeholderTarget.hidden = true
        if (this.hasFilenameTarget) this.filenameTarget.hidden = true
      }
      reader.readAsDataURL(file)
    } else {
      // Non-image (e.g. PDF): show placeholder and filename instead of preview.
      if (this.hasImgTarget) this.imgTarget.hidden = true
      if (this.hasPlaceholderTarget) this.placeholderTarget.hidden = false
      if (this.hasFilenameTarget) {
        this.filenameTarget.textContent = file.name
        this.filenameTarget.hidden = false
      }
    }
  }

  remove(event) {
    event.preventDefault()
    this.inputTarget.value = ""

    if (this.hasImgTarget) {
      this.imgTarget.hidden = true
      this.imgTarget.src = ""
    }
    if (this.hasPlaceholderTarget) this.placeholderTarget.hidden = false
    if (this.hasRemoveBtnTarget) this.removeBtnTarget.hidden = true
    if (this.hasRemoveFlagTarget) this.removeFlagTarget.value = "1"
    if (this.hasFilenameTarget) this.filenameTarget.hidden = true
  }
}
