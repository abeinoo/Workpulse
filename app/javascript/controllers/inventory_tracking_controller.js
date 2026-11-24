import { Controller } from "@hotwired/stimulus"

// Product Edit: while "Track stock quantity" is unticked, the whole
// "Product availability in warehouses" section (#availability, outside the
// product form) is hidden — every warehouse card, on-hand / reserved figure,
// threshold and reorder quantity. Purely visual: nothing is submitted or
// changed; ticking the box again shows the same cards. Whether tracking may
// be turned off is decided by the server when the product is saved.
export default class extends Controller {
  static values = { section: String }

  connect() {
    const checkbox = this.element.querySelector("input[type='checkbox'][name='product[track_inventory]']")
    if (checkbox) this.apply(checkbox.checked)
  }

  toggle(event) {
    this.apply(event.target.checked)
  }

  apply(tracked) {
    const section = this.sectionValue && document.getElementById(this.sectionValue)
    if (section) section.hidden = !tracked
  }
}
