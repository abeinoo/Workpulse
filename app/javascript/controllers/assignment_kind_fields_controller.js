import { Controller } from "@hotwired/stimulus"

// Shift assignment form: switches the employee and branch fields with the
// assignment kind. Regular picks from employees available for a new
// assignment and the manager's branches; temporary coverage picks from the
// scoped employees and a coverage (target) branch; floating uses the regular
// employee picker and has no branch at all. Every field is
// server-rendered — the inactive kind's are hidden and disabled so they are
// never submitted, and leaving coverage clears its selections.
export default class extends Controller {
  static targets = ["kind", "regular", "regularBranch", "floating", "coverage", "coverageEmployee", "coverageBranch", "route"]

  connect() {
    this.updateRoute()
  }

  toggle() {
    const coverage = this.kindTarget.value === "temporary_coverage"
    const floating = this.kindTarget.value === "floating"
    this.regularTargets.forEach((group) => this.#setActive(group, !coverage))
    this.regularBranchTargets.forEach((group) => this.#setActive(group, !coverage && !floating))
    this.floatingTargets.forEach((group) => group.classList.toggle("hidden", !floating))
    if (floating) this.regularBranchTargets.forEach((group) => this.#clear(group))
    this.coverageTargets.forEach((group) => this.#setActive(group, coverage))
    if (!coverage) this.coverageTargets.forEach((group) => this.#clear(group))
    this.updateRoute()
  }

  // "Current branch → coverage branch", once both are known.
  updateRoute() {
    if (!this.hasRouteTarget) return

    const from = this.coverageEmployeeTarget.selectedOptions[0]?.dataset.currentBranch
    const branch = this.coverageBranchTarget.selectedOptions[0]
    const to = branch?.value ? branch.textContent : null
    const show = Boolean(from && to)

    this.routeTarget.textContent = show
      ? this.routeTarget.dataset.template.replace("%{from}", from).replace("%{to}", to)
      : ""
    this.routeTarget.classList.toggle("hidden", !show)
  }

  #setActive(group, active) {
    group.classList.toggle("hidden", !active)
    group.querySelectorAll("select").forEach((select) => { select.disabled = !active })
  }

  #clear(group) {
    group.querySelectorAll("select").forEach((select) => { select.value = "" })
  }
}
