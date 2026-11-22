// A product's <option> in a product picker's (hidden) <select> — the one place
// the client builds it, from the server's product payload
// (Inventory::BaseController#product_picker_json): the product-combobox, the
// barcode scanner, the Low Stock picker and the PR item editor all go through
// here before selecting a product, so every existing listener keeps reading the
// same data attributes (default supplier, barcodes, SKU, thumbnail).
export function ensureProductOption(select, product) {
  const id = String(product.id)
  let option = Array.from(select.options).find((o) => o.value === id)
  if (!option) {
    option = document.createElement("option")
    option.value = id
    select.appendChild(option)
  }
  option.textContent = product.sku ? `${product.name} (${product.sku})` : product.name
  setData(option, "name", product.name)
  setData(option, "sku", product.sku)
  setData(option, "barcode", product.barcode)
  setData(option, "barcodes", (product.barcodes || (product.barcode ? [ product.barcode ] : [])).join("|"))
  setData(option, "defaultSupplierId", product.default_supplier_id ?? product.defaultSupplierId)
  setData(option, "measure", product.measure)
  setData(option, "thumb", product.thumb)
  return option
}

// Selects the product and notifies the line's listeners (supplier pre-fill,
// duplicate guard, totals, auto-submit) exactly like a user choice.
export function selectProduct(select, product) {
  ensureProductOption(select, product)
  select.value = String(product.id)
  select.dispatchEvent(new Event("change", { bubbles: true }))
}

function setData(el, key, value) {
  if (value === undefined || value === null || value === "") delete el.dataset[key]
  else el.dataset[key] = String(value)
}
