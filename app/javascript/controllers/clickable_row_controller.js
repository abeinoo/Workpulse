import { Controller } from "@hotwired/stimulus"

// Makes a <tr> navigate to a URL on click, without hijacking clicks on real
// links/buttons/inputs inside it (e.g. the document-number link keeps working
// as a normal, right-clickable/open-in-new-tab link).
export default class extends Controller {
  static values = { url: String }

  navigate(event) {
    if (event.target.closest("a, button, input, select, textarea, label")) return
    if (event.metaKey || event.ctrlKey || event.shiftKey) return

    Turbo.visit(this.urlValue)
  }
}
