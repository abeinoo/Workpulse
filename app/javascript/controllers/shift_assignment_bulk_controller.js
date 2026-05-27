import { Controller } from "@hotwired/stimulus"

// Manages the bulk-action bar on the shift-assignments index page.
//
// Responsibilities:
//   1. Show / hide the sticky bulk-action bar as checkboxes are toggled.
//   2. Keep the "X selected" count badge current.
//   3. Smart-disable individual action buttons when the selection makes them
//      irrelevant (e.g. Bulk Delete disabled when nothing deletable is chosen).
//   4. Open / close the Bulk Assign modal with a two-step conflict-preview flow:
//       a. User fills in shift / branch / date → clicks "Check Conflicts".
//       b. JS fetches bulk_assign_preview_shift_assignments_path (GET, JSON).
//       c. Preview panel shows N valid / N conflicting employees.
//       d. If ≥1 valid employee, the "Assign Shift" submit button is revealed.
//   5. Open / close the Bulk End modal and inject assignment_ids[] fields.
//   6. Build and submit the hidden Bulk Delete form after a confirm prompt.
//   7. Accessibility: ESC key closes any open modal; focus is trapped inside
//      open modals so keyboard-only users can't tab past them.

export default class extends Controller {
  static targets = [
    "actionBar",
    "countBadge",
    "bulkAssignBtn",
    "bulkEndBtn",
    "bulkDeleteBtn",
    // Bulk-assign modal
    "bulkAssignModal",
    "bulkAssignForm",
    "bulkAssignIds",
    "bulkAssignSubmitForm",
    "bulkAssignShiftSelect",
    "bulkAssignDateField",
    "conflictPreview",
    "checkConflictsBtn",
    "bulkAssignConfirmBtn",
    // Bulk-end modal
    "bulkEndModal",
    "bulkEndIds",
    // Bulk-delete hidden form
    "bulkDeleteForm",
    "bulkDeleteIds",
  ]

  // ── Lifecycle ──────────────────────────────────────────────────────────────

  connect() {
    this._syncBar()
    // Bind ESC listener to the document once; store reference for disconnect.
    this._onKeydown = this._handleKeydown.bind(this)
    document.addEventListener("keydown", this._onKeydown)
  }

  disconnect() {
    document.removeEventListener("keydown", this._onKeydown)
  }

  // ── Keyboard (ESC / Tab trap) ──────────────────────────────────────────────

  _handleKeydown(event) {
    if (event.key === "Escape") {
      if (this.hasBulkAssignModalTarget &&
          this.bulkAssignModalTarget.style.display !== "none") {
        this.closeBulkAssignModal()
        return
      }
      if (this.hasBulkEndModalTarget &&
          this.bulkEndModalTarget.style.display !== "none") {
        this.closeBulkEndModal()
      }
    }
    // Focus trap: when Tab is pressed inside an open modal, cycle focus only
    // among focusable children of that modal's .modal-card.
    if (event.key === "Tab") {
      const openModal = this._openModal()
      if (!openModal) return
      const card = openModal.querySelector(".modal-card")
      if (!card) return
      const focusable = Array.from(
        card.querySelectorAll(
          'a[href], button:not([disabled]), input, select, textarea, [tabindex]:not([tabindex="-1"])'
        )
      ).filter((el) => !el.closest("[hidden]") && !el.closest('[style*="display:none"]'))
      if (focusable.length === 0) return
      const first = focusable[0]
      const last  = focusable[focusable.length - 1]
      if (event.shiftKey) {
        if (document.activeElement === first) {
          event.preventDefault()
          last.focus()
        }
      } else {
        if (document.activeElement === last) {
          event.preventDefault()
          first.focus()
        }
      }
    }
  }

  // Returns the currently visible modal element, or null.
  _openModal() {
    if (this.hasBulkAssignModalTarget &&
        this.bulkAssignModalTarget.style.display !== "none") {
      return this.bulkAssignModalTarget
    }
    if (this.hasBulkEndModalTarget &&
        this.bulkEndModalTarget.style.display !== "none") {
      return this.bulkEndModalTarget
    }
    return null
  }

  // ── Checkbox state ─────────────────────────────────────────────────────────

  get allBoxes() {
    return Array.from(this.element.querySelectorAll(".bulk-check-row"))
  }

  get checkedBoxes() {
    return this.allBoxes.filter((b) => b.checked)
  }

  // Rows whose data-deletable="true" AND that are currently checked.
  get checkedDeletable() {
    return this.checkedBoxes.filter((b) => b.dataset.deletable === "true")
  }

  // Rows that are NOT future (i.e. current or historical) and are checked.
  // Bulk-end only makes sense for active / current assignments.
  get checkedEndable() {
    return this.checkedBoxes.filter((b) => b.dataset.future !== "true")
  }

  toggleAll(event) {
    const checked = event.target.checked
    this.allBoxes.forEach((b) => { b.checked = checked })
    this._syncBar()
  }

  rowChanged() {
    // Update master checkbox indeterminate state.
    const master = this.element.querySelector(".bulk-check-all")
    if (master) {
      const all     = this.allBoxes
      const checked = this.checkedBoxes
      master.checked       = all.length > 0 && checked.length === all.length
      master.indeterminate = checked.length > 0 && checked.length < all.length
    }
    this._syncBar()
  }

  // ── Bar sync ───────────────────────────────────────────────────────────────

  _syncBar() {
    const count     = this.checkedBoxes.length
    const hasAny    = count > 0
    const deletable = this.checkedDeletable.length
    const endable   = this.checkedEndable.length

    // Show / hide the whole bar.
    if (this.hasActionBarTarget) {
      this.actionBarTarget.style.display = hasAny ? "" : "none"
    }

    // Update count badge text.
    if (this.hasCountBadgeTarget) {
      this.countBadgeTarget.textContent = count
    }

    // Smart disable: Bulk Assign — always enabled when anything is selected.
    if (this.hasBulkAssignBtnTarget) {
      this._setDisabled(this.bulkAssignBtnTarget, !hasAny)
    }

    // Smart disable: Bulk End — disabled when all selected are future-only.
    if (this.hasBulkEndBtnTarget) {
      this._setDisabled(this.bulkEndBtnTarget, endable === 0)
    }

    // Smart disable: Bulk Delete — disabled when nothing deletable selected.
    if (this.hasBulkDeleteBtnTarget) {
      this._setDisabled(this.bulkDeleteBtnTarget, deletable === 0)
    }
  }

  _setDisabled(el, disabled) {
    el.disabled           = disabled
    el.setAttribute("aria-disabled", disabled ? "true" : "false")
  }

  // ── Bulk Assign ────────────────────────────────────────────────────────────

  openBulkAssignModal() {
    if (this.checkedBoxes.length === 0) return

    // Reset preview state from any previous open.
    this._resetPreview()

    // Inject one hidden input per selected employee (data-employee-id on each checkbox).
    if (this.hasBulkAssignIdsTarget) {
      this.bulkAssignIdsTarget.innerHTML = this.checkedBoxes
        .map((b) => {
          const empId = b.dataset.employeeId
          return empId
            ? `<input type="hidden" name="employee_ids[]" value="${empId}">`
            : ""
        })
        .join("")
    }

    if (this.hasBulkAssignModalTarget) {
      this.bulkAssignModalTarget.style.display = ""
      // Move focus to the first focusable element inside the modal card.
      requestAnimationFrame(() => {
        const card = this.bulkAssignModalTarget.querySelector(".modal-card")
        const first = card && card.querySelector(
          'select, input:not([type="hidden"]), button'
        )
        if (first) first.focus()
      })
    }
  }

  closeBulkAssignModal() {
    if (this.hasBulkAssignModalTarget) {
      this.bulkAssignModalTarget.style.display = "none"
    }
    // Return focus to the Assign button in the bulk bar.
    if (this.hasBulkAssignBtnTarget) this.bulkAssignBtnTarget.focus()
  }

  // Close modal when user clicks the overlay backdrop (outside the card).
  bulkAssignOverlayClick(event) {
    if (event.target === this.bulkAssignModalTarget) this.closeBulkAssignModal()
  }

  // ── Conflict preview ───────────────────────────────────────────────────────
  //
  // Triggered by the "Check Conflicts" button.  Fetches the preview JSON
  // endpoint, renders a summary panel, and (when ≥1 employee is valid) shows
  // the final "Assign Shift" submit button.

  async checkConflicts() {
    if (!this.hasConflictPreviewTarget) return

    const shiftId   = this.hasBulkAssignShiftSelectTarget
      ? this.bulkAssignShiftSelectTarget.value
      : null
    const fromDate  = this.hasBulkAssignDateFieldTarget
      ? this.bulkAssignDateFieldTarget.value
      : null
    const empIds    = this.checkedBoxes.map((b) => b.dataset.employeeId).filter(Boolean)

    if (!shiftId || !fromDate || empIds.length === 0) {
      this._showPreviewError("Please select a shift and start date.")
      return
    }

    // Show loading spinner.
    this.conflictPreviewTarget.style.display = ""
    this.conflictPreviewTarget.innerHTML = `
      <div class="conflict-preview">
        <div class="conflict-preview__loading">
          <span class="conflict-preview__spinner"></span>
          <span>${this._i18n("preview_loading")}</span>
        </div>
      </div>`

    if (this.hasCheckConflictsBtnTarget) {
      this.checkConflictsBtnTarget.disabled = true
    }

    // Build query string.
    const url  = this.bulkAssignModalTarget.dataset.bulkAssignPreviewUrl
    const qs   = new URLSearchParams({ shift_id: shiftId, effective_from: fromDate })
    empIds.forEach((id) => qs.append("employee_ids[]", id))

    try {
      const resp = await fetch(`${url}?${qs}`, {
        headers: { Accept: "application/json", "X-Requested-With": "XMLHttpRequest" },
        credentials: "same-origin",
      })

      if (!resp.ok) {
        this._showPreviewError(`Server error ${resp.status}`)
        return
      }

      const data = await resp.json()
      this._renderPreview(data)
    } catch (err) {
      this._showPreviewError(err.message || "Network error")
    } finally {
      if (this.hasCheckConflictsBtnTarget) {
        this.checkConflictsBtnTarget.disabled = false
      }
    }
  }

  _renderPreview(data) {
    const { valid = [], conflicting = [] } = data
    const validCount    = valid.length
    const conflictCount = conflicting.length

    const validLabel    = validCount === 1
      ? this._i18n("preview_valid_one")
      : this._i18n("preview_valid_other").replace("%{count}", validCount)
    const conflictLabel = conflictCount === 1
      ? this._i18n("preview_conflict_one")
      : this._i18n("preview_conflict_other").replace("%{count}", conflictCount)

    // Build rows for valid employees.
    const validRows = valid.map((e) => `
      <div class="conflict-preview__row conflict-preview__row--ok">
        <span class="conflict-preview__dot conflict-preview__dot--ok"></span>
        <span>${this._esc(e.name)}</span>
      </div>`).join("")

    // Build rows for conflicting employees.
    const conflictRows = conflicting.map((e) => `
      <div class="conflict-preview__row conflict-preview__row--warn">
        <span class="conflict-preview__dot conflict-preview__dot--warn"></span>
        <span>
          ${this._esc(e.name)}
          <span class="conflict-preview__reason">${this._esc(e.reason)}</span>
        </span>
      </div>`).join("")

    this.conflictPreviewTarget.innerHTML = `
      <div class="conflict-preview">
        <div class="conflict-preview__header">
          <span class="conflict-preview__stat conflict-preview__stat--ok">
            ✓ ${this._esc(validLabel)}
          </span>
          ${conflictCount > 0 ? `
            <span class="conflict-preview__stat conflict-preview__stat--warn">
              ⚠ ${this._esc(conflictLabel)}
            </span>` : ""}
        </div>
        <div class="conflict-preview__list">
          ${validRows}${conflictRows}
        </div>
      </div>`

    // Reveal the final submit button only when ≥1 employee can be assigned.
    if (this.hasBulkAssignConfirmBtnTarget) {
      this.bulkAssignConfirmBtnTarget.style.display = validCount > 0 ? "" : "none"
    }
  }

  _showPreviewError(msg) {
    if (!this.hasConflictPreviewTarget) return
    this.conflictPreviewTarget.style.display = ""
    this.conflictPreviewTarget.innerHTML = `
      <div class="conflict-preview">
        <div class="conflict-preview__loading" style="color:var(--danger,#ef4444)">
          ✕ ${this._esc(msg)}
        </div>
      </div>`
  }

  _resetPreview() {
    if (this.hasConflictPreviewTarget) {
      this.conflictPreviewTarget.style.display = "none"
      this.conflictPreviewTarget.innerHTML = ""
    }
    if (this.hasBulkAssignConfirmBtnTarget) {
      this.bulkAssignConfirmBtnTarget.style.display = "none"
    }
  }

  // Pull an i18n string from a <meta> tag written by the view layer.
  // Falls back to the key itself so the UI never shows undefined.
  _i18n(key) {
    const el = document.querySelector(`meta[name="sa-bulk-i18n-${key}"]`)
    return el ? el.getAttribute("content") : key
  }

  // Escape HTML to prevent XSS when injecting server data into innerHTML.
  _esc(str) {
    return String(str)
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;")
  }

  // ── Bulk End ───────────────────────────────────────────────────────────────

  openBulkEndModal() {
    const endable = this.checkedEndable
    if (endable.length === 0) return

    if (this.hasBulkEndIdsTarget) {
      this.bulkEndIdsTarget.innerHTML = endable
        .map((b) => `<input type="hidden" name="assignment_ids[]" value="${b.value}">`)
        .join("")
    }

    if (this.hasBulkEndModalTarget) {
      this.bulkEndModalTarget.style.display = ""
      requestAnimationFrame(() => {
        const card  = this.bulkEndModalTarget.querySelector(".modal-card")
        const first = card && card.querySelector('input[type="date"], button')
        if (first) first.focus()
      })
    }
  }

  closeBulkEndModal() {
    if (this.hasBulkEndModalTarget) {
      this.bulkEndModalTarget.style.display = "none"
    }
    if (this.hasBulkEndBtnTarget) this.bulkEndBtnTarget.focus()
  }

  bulkEndOverlayClick(event) {
    if (event.target === this.bulkEndModalTarget) this.closeBulkEndModal()
  }

  // ── Bulk Delete ────────────────────────────────────────────────────────────

  bulkDelete(event) {
    const deletable = this.checkedDeletable
    if (deletable.length === 0) return

    const template = event.currentTarget.dataset.confirmTemplate || ""
    const message  = template.replace("%{count}", deletable.length).replace("0", deletable.length)
    if (!confirm(message)) return

    if (this.hasBulkDeleteIdsTarget) {
      this.bulkDeleteIdsTarget.innerHTML = deletable
        .map((b) => `<input type="hidden" name="assignment_ids[]" value="${b.value}">`)
        .join("")
    }

    if (this.hasBulkDeleteFormTarget) {
      this.bulkDeleteFormTarget.requestSubmit
        ? this.bulkDeleteFormTarget.requestSubmit()
        : this.bulkDeleteFormTarget.submit()
    }
  }
}
