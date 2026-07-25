import { Controller } from "@hotwired/stimulus"

// Submits the enclosing form as soon as a field inside it changes — used for
// standalone filter selectors (e.g. the header branch picker) that should
// apply immediately rather than waiting for an explicit "Apply" button.
//
// data-controller="auto-submit"
// data-action="change->auto-submit#submit"
export default class extends Controller {
  submit() {
    this.element.closest("form").requestSubmit()
  }
}
