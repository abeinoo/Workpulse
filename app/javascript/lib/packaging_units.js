// The unit a document line is entered in (docs/inventory/multi_unit_nested_packaging_design.md §7):
// a line row holds
//   <select data-unit-select name="…[packaging_level_id]">   base unit + packaging levels
//   <input  data-quantity-field name="…[entered_quantity]">   amount in that unit
//   <span   data-unit-hint>                                   "= 30 pcs" (live)
// The options come from the chosen product's <option data-units='[…]'>
// (InventoryHelper#packaging_units, lib/product_option.js). A product without
// packaging shows only its measure label. The server derives the base
// quantity itself; this only guides the user.
export function installPackagingUnits(root = document) {
  root.addEventListener("change", (event) => {
    const el = event.target
    if (el instanceof HTMLSelectElement && el.matches("select[data-product-field]")) rebuild(el.closest("[data-line-row]"), el)
    if (el instanceof HTMLSelectElement && el.matches("select[data-unit-select]")) updateHint(el.closest("[data-line-row]"))
  })
  root.addEventListener("click", (event) => {
    const button = event.target.closest?.("[data-packaging-split]")
    if (button) splitRow(button.closest("[data-line-row]"))
  })
  root.addEventListener("input", (event) => {
    if (event.target.matches?.("[data-count-breakdown] input")) return sumBreakdown(event.target.closest("[data-line-row]"))
    if (event.target.matches?.("[data-line-row] [data-quantity-field]")) updateHint(event.target.closest("[data-line-row]"))
  })
}

function unitsOf(productSelect) {
  const raw = productSelect?.selectedOptions[0]?.dataset.units
  if (!raw) return []
  try { return JSON.parse(raw) } catch { return [] }
}

// Rebuilds a row's unit selector from its product <option>'s data-units and
// selects `levelId` ("" = base unit) — for rows filled programmatically
// (the purchase request item editor).
export function refreshUnits(row, levelId = "") {
  const productSelect = row?.querySelector("select[data-product-field]")
  if (!productSelect) return
  rebuild(row, productSelect)
  const select = row.querySelector("select[data-unit-select]")
  if (select && [ ...select.options ].some((o) => o.value === String(levelId ?? ""))) select.value = String(levelId ?? "")
  updateHint(row)
}

function rebuild(row, productSelect) {
  const select = row?.querySelector("select[data-unit-select]")
  if (!select) return
  const units = unitsOf(productSelect)
  const keep = select.value
  select.innerHTML = ""
  units.forEach((unit) => {
    const option = document.createElement("option")
    option.value = unit.id == null ? "" : String(unit.id)
    option.textContent = unit.label
    option.dataset.base = unit.base
    select.appendChild(option)
  })
  if ([ ...select.options ].some((o) => o.value === keep)) select.value = keep
  const packaged = units.length > 1
  select.hidden = !packaged
  select.disabled = !packaged
  const label = row.querySelector("[data-measure-label]")
  const measure = productSelect?.selectedOptions[0]?.dataset.measure
  if (label && measure !== undefined) label.textContent = measure
  if (label) label.hidden = packaged
  updateHint(row)
}

function updateHint(row) {
  const hint = row?.querySelector("[data-unit-hint]")
  const select = row?.querySelector("select[data-unit-select]")
  if (!hint || !select) return
  const option = select.selectedOptions[0]
  const base = parseFloat(option?.dataset.base || "1")
  const qty = parseFloat(row.querySelector("[data-quantity-field]")?.value)
  const measure = row.querySelector("[data-measure-label]")?.textContent || ""
  if (select.hidden || !option || option.value === "" || !Number.isFinite(qty)) {
    hint.textContent = ""
    return
  }
  const total = Math.round(qty * base * 1000) / 1000
  hint.textContent = (hint.dataset.template || "= %{base}").replace("%{base}", `${total} ${measure}`.trim())
}

// A receipt line from a purchase request received in two units (e.g. 1 carton
// on this row + 6 boxes on a copy): the copy is a NEW line for the same
// request line — same product and purchase_request_item_id, empty amount.
function splitRow(row) {
  if (!row) return
  const copy = row.cloneNode(true)
  const key = String(Date.now())
  copy.querySelectorAll("[name]").forEach((el) => {
    el.name = el.name.replace(/\[items_attributes\]\[[^\]]+\]/, `[items_attributes][${key}]`)
    if (el.id) el.id = `${el.id}_${key}`
  })
  copy.querySelectorAll('input[name$="[id]"], input[data-destroy-field]').forEach((el) => el.remove())
  copy.querySelectorAll("[data-quantity-field]").forEach((el) => { el.value = "" })
  copy.querySelectorAll("[data-line-total]").forEach((el) => { el.textContent = "—" })
  copy.querySelectorAll("[data-packaging-split]").forEach((el) => el.remove())
  copy.querySelectorAll(".text-danger").forEach((el) => el.remove())
  row.after(copy)
  updateHint(copy)
  copy.querySelector("[data-quantity-field]")?.focus()
}

// Stocktake row counted per packaging level: the total (base units) is the
// sum of packages × their base quantity plus loose content; it is written to
// the row's counted field and announced like typing there (count-sheet marks
// the row entered and shows the difference).
function sumBreakdown(row) {
  const field = row?.querySelector("[data-quantity-field]")
  if (!field) return
  let total = 0
  let any = false
  row.querySelectorAll("[data-count-breakdown] input").forEach((input) => {
    if (input.value.trim() === "") return
    any = true
    total += (parseFloat(input.value) || 0) * parseFloat(input.dataset.breakdownBase || "1")
  })
  field.value = any ? String(Math.round(total * 1000) / 1000) : ""
  field.dispatchEvent(new Event("input", { bubbles: true }))
}
