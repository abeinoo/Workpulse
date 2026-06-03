import { Controller } from "@hotwired/stimulus"

/**
 * bulk-attendance-form
 *
 * Spreadsheet-style bulk manual attendance entry:
 *  - Dynamic add / remove rows
 *  - Mass-set Date across all rows (the common "fill yesterday for the shift" case)
 *  - Keyboard navigation: Enter / Arrow up-down moves down/up the same column
 *  - Clipboard paste: tab- or comma-separated
 *      employee_code, work_date, check_in, check_out, notes
 *    Employees are matched by employee_code ONLY (no name matching).
 *  - Live filled-row counter
 *
 * Grid cells use native date/time inputs (theme-aware) rather than Flatpickr so
 * dynamically-inserted rows and paste stay robust.
 */
export default class extends Controller {
  static targets = ["body", "template", "emptyState", "totalRows", "massDate"]

  connect() {
    if (this.bodyTarget.querySelectorAll("[data-bulk-row]").length === 0) this.addRow()
    this.updateCount()
    this.#syncEmptyState()
  }

  addRow(event) {
    event?.preventDefault()
    const index = `${Date.now()}${Math.floor(Math.random() * 1000)}`
    const html  = this.templateTarget.innerHTML.replaceAll("NEW_INDEX", index)
    this.bodyTarget.insertAdjacentHTML("beforeend", html)
    this.#syncEmptyState()
    this.updateCount()
    this.bodyTarget.lastElementChild?.querySelector("select,input")?.focus()
  }

  removeRow(event) {
    event.preventDefault()
    event.currentTarget.closest("[data-bulk-row]")?.remove()
    if (this.bodyTarget.querySelectorAll("[data-bulk-row]").length === 0) this.addRow()
    this.#syncEmptyState()
    this.updateCount()
  }

  massSetDate(event) {
    event.preventDefault()
    const value = this.hasMassDateTarget ? this.massDateTarget.value : ""
    if (!value) return
    this.#cells("[data-field='work_date']").forEach(el => { el.value = value })
  }

  updateCount() {
    let filled = 0
    this.bodyTarget.querySelectorAll("[data-bulk-row]").forEach(row => {
      const emp = row.querySelector("[data-field='user_id']")
      const ci  = row.querySelector("[data-field='check_in']")
      if (emp?.value && ci?.value) filled++
    })
    if (this.hasTotalRowsTarget) this.totalRowsTarget.textContent = filled
  }

  handleKeydown(event) {
    const el  = event.target
    const row = el.closest("[data-bulk-row]")
    if (!row) return

    if (event.key === "Enter") {
      event.preventDefault()
      const cells   = Array.from(row.querySelectorAll("input,select"))
      const idx     = cells.indexOf(el)
      const nextRow = row.nextElementSibling
      if (nextRow) {
        nextRow.querySelectorAll("input,select")[idx]?.focus()
      } else {
        this.addRow()
      }
    }

    if ((event.key === "ArrowDown" || event.key === "ArrowUp") && !event.shiftKey) {
      const sibling = event.key === "ArrowDown" ? row.nextElementSibling : row.previousElementSibling
      if (!sibling) return
      const cells = Array.from(row.querySelectorAll("input,select"))
      const idx   = cells.indexOf(el)
      sibling.querySelectorAll("input,select")[idx]?.focus()
      event.preventDefault()
    }
  }

  handlePaste(event) {
    if (event.target.tagName === "INPUT" || event.target.tagName === "SELECT") return
    const text = event.clipboardData?.getData("text/plain")
    if (!text) return
    event.preventDefault()

    text.split("\n").map(l => l.trim()).filter(Boolean).forEach(line => {
      const sep   = line.includes("\t") ? "\t" : ","
      const parts = line.split(sep).map(p => p?.trim())
      const [code, workDate, checkIn, checkOut, notes] = parts
      if (!code) return

      const index = `${Date.now()}${Math.floor(Math.random() * 1000)}`
      const html  = this.templateTarget.innerHTML.replaceAll("NEW_INDEX", index)
      this.bodyTarget.insertAdjacentHTML("beforeend", html)
      const row = this.bodyTarget.lastElementChild

      const empSelect = row.querySelector("[data-field='user_id']")
      if (empSelect) {
        const opt = Array.from(empSelect.options).find(o =>
          o.dataset.code && o.dataset.code.toLowerCase() === code.toLowerCase()
        )
        if (opt) empSelect.value = opt.value
      }
      this.#set(row, "work_date", workDate)
      this.#set(row, "check_in",  checkIn)
      this.#set(row, "check_out", checkOut)
      this.#set(row, "notes",     notes)
    })

    this.#syncEmptyState()
    this.updateCount()
  }

  #set(row, field, value) {
    if (!value) return
    const el = row.querySelector(`[data-field='${field}']`)
    if (el) el.value = value
  }

  #cells(selector) {
    return Array.from(this.bodyTarget.querySelectorAll(`[data-bulk-row] ${selector}`))
  }

  #syncEmptyState() {
    if (!this.hasEmptyStateTarget) return
    this.emptyStateTarget.hidden = this.bodyTarget.querySelectorAll("[data-bulk-row]").length > 0
  }
}
