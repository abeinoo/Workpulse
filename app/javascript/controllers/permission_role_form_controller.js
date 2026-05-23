import { Controller } from "@hotwired/stimulus"

// deps:  { "manage_attendance": ["view_attendance"], ... }
// When checking a permission: auto-check its required dependencies.
// When unchecking a permission: auto-uncheck any permissions that depend on it.

export default class extends Controller {
  static targets = ["group", "groupToggle", "checkbox", "scopeRow", "scopeSelect",
                    "searchInput", "groupsContainer", "noResults"]
  static values  = { deps: Object }  // populated from data-permission-role-form-deps-value

  connect() {
    this.updateAllGroupToggles()
  }

  // ── Bulk select ────────────────────────────────────────────────────────────

  selectAll() {
    this.checkboxTargets.forEach(cb => { cb.checked = true })
    this._syncAllScopeRows()
    this.updateAllGroupToggles()
  }

  clearAll() {
    this.checkboxTargets.forEach(cb => { cb.checked = false })
    this._syncAllScopeRows()
    this.updateAllGroupToggles()
  }

  // ── Group toggle ───────────────────────────────────────────────────────────

  toggleGroup(event) {
    const toggle = event.currentTarget
    const group  = toggle.closest("[data-permission-role-form-target~='group']")
    group.querySelectorAll("[data-permission-role-form-target~='checkbox']")
         .forEach(cb => {
           if (cb.checked !== toggle.checked) {
             cb.checked = toggle.checked
             this._enforceDependencies(cb)
             this._syncScopeRow(cb)
           }
         })
  }

  updateGroupToggle(event) {
    const group = event.currentTarget
                       .closest("[data-permission-role-form-target~='group']")
    if (!group) return
    this._syncGroupToggle(group)
  }

  updateAllGroupToggles() {
    this.groupTargets.forEach(g => this._syncGroupToggle(g))
  }

  // ── Per-permission change: enforce dependency rules ────────────────────────

  onPermissionChange(event) {
    const cb = event.currentTarget
    this._enforceDependencies(cb)
    this._syncScopeRow(cb)
    this.updateAllGroupToggles()
  }

  // ── Search / filter ───────────────────────────────────────────────────────

  filterPermissions() {
    const query = this.searchInputTarget.value.trim().toLowerCase()
    let anyVisible = false

    this.groupTargets.forEach(group => {
      const cards = group.querySelectorAll(".permission-card")
      let groupHasMatch = false

      cards.forEach(card => {
        const name = (card.dataset.permName || "").toLowerCase()
        const match = !query || name.includes(query)
        card.style.display = match ? "" : "none"
        if (match) groupHasMatch = true
      })

      group.style.display = groupHasMatch ? "" : "none"
      if (groupHasMatch) anyVisible = true
    })

    this.noResultsTarget.style.display = anyVisible ? "none" : ""
  }

  // ── Private helpers ───────────────────────────────────────────────────────

  _enforceDependencies(checkbox) {
    const perm = checkbox.dataset.perm
    if (!perm) return

    if (checkbox.checked) {
      // Auto-enable required dependencies.
      const deps = (this.depsValue[perm] || [])
      deps.forEach(dep => {
        const depCb = this._checkboxFor(dep)
        if (depCb && !depCb.checked) {
          depCb.checked = true
          this._syncScopeRow(depCb)
          this._highlightCard(depCb, "auto-enabled")
        }
      })
    } else {
      // Auto-disable permissions that depend on this one.
      const dependents = this._dependentsOf(perm)
      dependents.forEach(dependent => {
        const depCb = this._checkboxFor(dependent)
        if (depCb && depCb.checked) {
          depCb.checked = false
          this._syncScopeRow(depCb)
          this._highlightCard(depCb, "auto-disabled")
        }
      })
    }
  }

  // Build the reverse map lazily: dep → [permissions that need it]
  _dependentsOf(perm) {
    if (!this._dependentsCache) {
      this._dependentsCache = {}
      for (const [p, deps] of Object.entries(this.depsValue)) {
        deps.forEach(dep => {
          this._dependentsCache[dep] = this._dependentsCache[dep] || []
          this._dependentsCache[dep].push(p)
        })
      }
    }
    return this._dependentsCache[perm] || []
  }

  _checkboxFor(perm) {
    return this.checkboxTargets.find(cb => cb.dataset.perm === perm)
  }

  // Briefly pulse the card to indicate an automatic change.
  _highlightCard(checkbox, state) {
    const card = checkbox.closest(".permission-card")
    if (!card) return
    card.classList.add(`permission-card--${state}`)
    setTimeout(() => card.classList.remove(`permission-card--${state}`), 1400)
  }

  _syncGroupToggle(group) {
    const boxes  = [...group.querySelectorAll("[data-permission-role-form-target~='checkbox']")]
    const toggle = group.querySelector("[data-permission-role-form-target~='groupToggle']")
    if (!toggle) return
    const all  = boxes.every(b => b.checked)
    const some = boxes.some(b => b.checked)
    toggle.checked       = all
    toggle.indeterminate = !all && some
  }

  _syncScopeRow(checkbox) {
    const perm = checkbox.dataset.perm
    if (!perm) return
    const row = this.scopeRowTargets.find(r => r.dataset.forPerm === perm)
    if (!row) return
    row.style.display = checkbox.checked ? "" : "none"
  }

  _syncAllScopeRows() {
    this.checkboxTargets.forEach(cb => this._syncScopeRow(cb))
  }
}
