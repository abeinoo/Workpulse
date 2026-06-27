import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["branchSelect", "allocationSection"]

  branchChanged() {
    if (!this.hasAllocationSectionTarget) return
    this.allocationSectionTarget.hidden = this.branchSelectTarget.value !== ""
  }
}
