import { Controller } from "@hotwired/stimulus"

// Column-mapping step of a CSV import (Inventory stock issues). When the user
// changes a mapping dropdown, show that column's name + sample values right
// away, and disable "Import" until the preview is refreshed — so what gets
// imported is always what the preview showed. The server re-validates the
// mapping on import regardless.
export default class extends Controller {
  static targets = ["select", "source", "importButton", "staleNotice"]
  static values = { columns: Array }

  changed(event) {
    const select = event.target
    const source = this.sourceTargets.find((el) => el.dataset.field === select.dataset.field)
    if (source) this.renderSource(source, select.value)

    this.importButtonTargets.forEach((button) => { button.disabled = true })
    if (this.hasStaleNoticeTarget) this.staleNoticeTarget.hidden = false
  }

  renderSource(el, value) {
    el.textContent = ""
    const column = value === "" ? null : this.columnsValue[Number(value)]
    if (!column) {
      el.textContent = this.element.dataset.notMappedText || ""
      return
    }

    el.append(`${this.element.dataset.csvColumnText}: `)
    const name = document.createElement("strong")
    const nameBdi = document.createElement("bdi")
    nameBdi.textContent = column.name
    name.append(nameBdi)
    el.append(name)

    if (column.samples.length) {
      el.append(document.createElement("br"), `${this.element.dataset.examplesText}: `)
      const samples = document.createElement("bdi")
      samples.textContent = column.samples.join(" · ")
      el.append(samples)
    }
  }
}
