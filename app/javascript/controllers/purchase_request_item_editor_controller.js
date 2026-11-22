import { Controller } from "@hotwired/stimulus"
import { ensureProductOption } from "lib/product_option"
import { refreshUnits } from "lib/packaging_units"

// The Purchase Request page's item editor (_item_editor.html.erb): one modal
// for "Add Product" and every row's "Edit". This controller only fills the
// modal from the clicked button and opens / closes it. The line itself —
// live line total, request total, supplier pre-fill rule, number checks — is
// the ordinary line row under purchase_request_form_controller, and saving goes
// through Inventory::PurchaseRequestUpdater, which enforces every rule.
export default class extends Controller {
  static targets = ["modal", "form", "method", "title"]

  connect() {
    this._onKeydown = (event) => {
      if (event.key === "Escape" && this._isOpen()) this.close()
    }
    document.addEventListener("keydown", this._onKeydown)
  }

  disconnect() {
    document.removeEventListener("keydown", this._onKeydown)
  }

  openAdd(event) {
    this._open(event.currentTarget, "post", { productId: "", supplierId: "", quantity: "", unitPrice: "", lineTotal: "0" })
  }

  openEdit(event) {
    this._open(event.currentTarget, "patch", event.currentTarget.dataset)
  }

  close() {
    this.modalTarget.style.display = "none"
  }

  _open(button, method, line) {
    const form = this.formTarget
    form.action = button.dataset.url
    this.methodTarget.value = method
    this.titleTarget.textContent = method === "post" ? this.titleTarget.dataset.addTitle : this.titleTarget.dataset.editTitle

    // "Request total after saving" = the other lines + this one.
    const requestTotal = parseFloat(this.modalTarget.dataset.requestTotal) || 0
    form.dataset.purchaseRequestFormBaseTotalValue = String(requestTotal - (parseFloat(line.lineTotal) || 0))

    const product = form.querySelector("[data-product-field]")
    if (line.productId) {
      ensureProductOption(product, { id: line.productId, name: line.productName, sku: line.sku, thumb: line.thumb,
                                     default_supplier_id: line.defaultSupplierId, measure: line.measure,
                                     units: line.units ? JSON.parse(line.units) : null })
    }
    product.value = line.productId || ""
    product.dataset.previousValue = product.value
    product.dispatchEvent(new CustomEvent("pcombo:refresh")) // the picker shows it, no change listeners
    const input = form.querySelector("[data-product-combobox-target='input']")

    form.querySelector("[data-supplier-field]").value = line.supplierId || ""
    form.querySelector("[data-supplier-kept-note]")?.setAttribute("hidden", "")
    form.querySelector("[data-quantity-field]").value = line.quantity || ""
    form.querySelector("[data-price-field]").value = line.unitPrice || ""
    // The line's unit (a packaging level, or the base unit) and the product's units.
    refreshUnits(form.querySelector("[data-line-row]"), line.packagingLevelId || "")
    form.querySelector("[data-purchase-request-form-target='duplicateNotice']")?.setAttribute("hidden", "")

    this.modalTarget.style.display = ""
    // Recalculate once the base total value has reached the form controller.
    requestAnimationFrame(() => {
      form.querySelector("[data-quantity-field]").dispatchEvent(new Event("input", { bubbles: true }))
      ;(line.productId ? form.querySelector("[data-quantity-field]") : input || product)?.focus()
    })
  }

  _isOpen() {
    return this.hasModalTarget && this.modalTarget.style.display !== "none"
  }
}
