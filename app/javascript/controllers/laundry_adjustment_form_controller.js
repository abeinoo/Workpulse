import { Controller } from "@hotwired/stimulus"

// Toggles between the generic "correction" fields (status + signed
// adjustment quantity) and the guided "lost"/"damaged" field (a single
// unsigned quantity) based on the selected adjustment type — keeps the raw
// ledger-status concept hidden for the guided loss/damage path.
export default class extends Controller {
  static targets = ["typeSelect", "correctionSection", "lossSection"]

  connect() {
    this.update()
  }

  update() {
    const isLoss = [ "lost", "damaged" ].includes(this.typeSelectTarget.value)

    if (this.hasCorrectionSectionTarget) this.correctionSectionTarget.hidden = isLoss
    if (this.hasLossSectionTarget) this.lossSectionTarget.hidden = !isLoss
  }
}
