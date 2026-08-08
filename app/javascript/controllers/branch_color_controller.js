import { Controller } from "@hotwired/stimulus"
import { colorForLabel } from "charts/defaults"

// Paints a small swatch dot with the same deterministic per-label color the
// doughnut/pie charts already use (colorForLabel), so a given branch reads
// as the same color everywhere it appears — ranking rows, branch cards, and
// any revenue/expense-by-branch chart.
export default class extends Controller {
  static values = { label: String }

  connect() {
    this.element.style.setProperty("--swatch-color", colorForLabel(this.labelValue))
  }
}
