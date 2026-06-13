import { Controller } from "@hotwired/stimulus"

// Drives the observation form's employee → department → criteria chain.
// When an employee is picked it fetches that employee's department and the
// active criteria for the department's template, then:
//   - shows the (read-only) department name,
//   - repopulates the criteria dropdown with ONLY those criteria,
//   - if the employee has no department, shows a warning and disables saving.
export default class extends Controller {
  static targets = ["employee", "department", "criterion", "warning", "submit"]
  static values = { url: String, placeholder: String, selectPrompt: String }

  change() {
    const employeeId = this.employeeTarget.value
    if (!employeeId) {
      this.#reset()
      return
    }

    const url = new URL(this.urlValue, window.location.origin)
    url.searchParams.set("employee_id", employeeId)

    fetch(url, { headers: { Accept: "application/json" } })
      .then((r) => r.json())
      .then((data) => this.#apply(data))
      .catch(() => this.#reset())
  }

  #apply(data) {
    this.departmentTarget.textContent = data.has_department
      ? data.department.name
      : this.placeholderValue

    this.#fillCriteria(data.criteria)
    this.#toggleBlocked(data.employee_selected && !data.has_department)
  }

  #fillCriteria(criteria) {
    const select = this.criterionTarget
    select.innerHTML = ""

    const prompt = document.createElement("option")
    prompt.value = ""
    prompt.textContent = this.selectPromptValue
    select.appendChild(prompt)

    criteria.forEach(({ id, name }) => {
      const option = document.createElement("option")
      option.value = id
      option.textContent = name
      select.appendChild(option)
    })
  }

  #toggleBlocked(blocked) {
    if (this.hasWarningTarget) this.warningTarget.hidden = !blocked
    this.criterionTarget.disabled = blocked
    if (this.hasSubmitTarget) this.submitTarget.disabled = blocked
  }

  #reset() {
    this.departmentTarget.textContent = this.placeholderValue
    this.#fillCriteria([])
    this.#toggleBlocked(false)
  }
}
