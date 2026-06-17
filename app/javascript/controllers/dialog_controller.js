import { Controller } from "@hotwired/stimulus"

// Opens a native <dialog> element as a modal.
// Usage:
//   <div data-controller="dialog">
//     <button data-action="click->dialog#open">Open</button>
//     <dialog data-dialog-target="modal" data-action="click->dialog#backdropClose">
//       ...
//       <button data-action="click->dialog#close">Close</button>
//     </dialog>
//   </div>
export default class extends Controller {
  static targets = ["modal"]

  open() {
    this.modalTarget.showModal()
  }

  close() {
    this.modalTarget.close()
  }

  // Close when clicking the backdrop (the <dialog> element itself, not its children)
  backdropClose(event) {
    if (event.target === this.modalTarget) {
      this.modalTarget.close()
    }
  }
}
