import { Controller } from "@hotwired/stimulus"

// Shows a read-only "inferred condition" hint client-side (display only —
// the server always re-derives it independently and rejects any combination
// it can't infer) as the From/To branches are picked. There is no manual
// override: the condition is always inferred from branch types.
//
// branchTypesValue is a { [branchId]: branchType } map rendered by the view.
export default class extends Controller {
  static targets = ["sourceSelect", "destinationSelect", "inferredHint"]
  static values  = { branchTypes: Object, dirtyLabel: String, cleanLabel: String }

  connect() {
    this.update()
  }

  update() {
    const sourceType      = this.#typeFor(this.sourceSelectTarget.value)
    const destinationType = this.#typeFor(this.destinationSelectTarget.value)
    const inferred         = this.#infer(sourceType, destinationType)

    if (this.hasInferredHintTarget) {
      this.inferredHintTarget.hidden = !inferred
      if (inferred) this.inferredHintTarget.textContent = inferred.label
    }
  }

  #typeFor(branchId) {
    return branchId ? this.branchTypesValue[branchId] : null
  }

  #infer(sourceType, destinationType) {
    if (sourceType === "sales" && destinationType === "laundry") return { status: "dirty", label: this.dirtyLabelValue }
    if (sourceType === "laundry" && destinationType === "sales") return { status: "clean", label: this.cleanLabelValue }
    if (sourceType === "sales" && destinationType === "sales")   return { status: "clean", label: this.cleanLabelValue }
    return null
  }
}
