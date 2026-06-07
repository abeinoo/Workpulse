import { Controller } from "@hotwired/stimulus"

// On a goods receipt, when a product with a default supplier is chosen, pre-fill
// the (single) header supplier select — but only when it's still blank, so a
// manual choice is never overwritten and multi-supplier receipts still work.
export default class extends Controller {
  static targets = ["supplier"]

  productChanged(event) {
    if (!this.hasSupplierTarget) return
    if (this.supplierTarget.value) return // respect a manual / existing choice

    const option = event.target.selectedOptions[0]
    const supplierId = option?.dataset.defaultSupplierId
    if (supplierId) this.supplierTarget.value = supplierId
  }
}
