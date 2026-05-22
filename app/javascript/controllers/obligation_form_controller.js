import { Controller } from "@hotwired/stimulus"

const MAX_SCHEDULE_ROWS = 120

export default class extends Controller {
  static targets = ["total", "installment", "startMonth", "startYear", "preview", "schedule", "scheduleSection"]

  calculate() {
    const total = parseFloat(this.totalTarget.value) || 0
    const installment = parseFloat(this.installmentTarget.value) || 0

    if (total <= 0 || installment <= 0 || installment > total) {
      this.previewTarget.textContent = "—"
      this.previewTarget.classList.add("text-muted")
      this.hideSchedule()
      return
    }

    const count = Math.ceil(total / installment)
    // Round to 2dp to avoid floating-point drift (e.g. 5000 % 900 = 500.0000000001)
    const remainder = Math.round((total % installment) * 100) / 100
    const hasRemainder = remainder > 0
    const fullCount = hasRemainder ? count - 1 : count

    if (hasRemainder) {
      this.previewTarget.textContent =
        `${fullCount} × ${this.fmt(installment)} + ${this.finalLabel()}: ${this.fmt(remainder)}`
    } else {
      this.previewTarget.textContent = `${count} × ${this.fmt(installment)}`
    }
    this.previewTarget.classList.remove("text-muted")

    this.renderSchedule(installment, count, remainder, hasRemainder)
  }

  renderSchedule(installment, count, remainder, hasRemainder) {
    const startMonth = parseInt(this.startMonthTarget.value) || (new Date().getMonth() + 1)
    const startYear  = parseInt(this.startYearTarget.value)  || new Date().getFullYear()
    const locale     = document.documentElement.lang || "en"
    const finalLabel = this.finalLabel()
    const rowCount   = Math.min(count, MAX_SCHEDULE_ROWS)

    const rows = []
    for (let i = 0; i < rowCount; i++) {
      const isLast   = i === count - 1
      const amount   = (isLast && hasRemainder) ? remainder : installment
      const date     = new Date(startYear, startMonth - 1 + i, 1)
      const monthStr = date.toLocaleDateString(locale, { month: "short", year: "numeric" })
      const amtStr   = this.fmt(amount)
      const badge    = (isLast && hasRemainder)
        ? ` <span style="font-size:10px;padding:1px 5px;background:var(--bg-3,#f1f5f9);border-radius:3px;color:var(--text-2);">${finalLabel}</span>`
        : ""
      rows.push(`<tr><td>${monthStr}</td><td>${amtStr}${badge}</td></tr>`)
    }

    if (count > MAX_SCHEDULE_ROWS) {
      rows.push(`<tr><td colspan="2" style="color:var(--text-3);font-style:italic;">… ${count - MAX_SCHEDULE_ROWS} more</td></tr>`)
    }

    this.scheduleTarget.innerHTML = rows.join("")
    this.scheduleSectionTarget.style.display = ""
  }

  hideSchedule() {
    if (this.hasScheduleSectionTarget) {
      this.scheduleSectionTarget.style.display = "none"
    }
    if (this.hasScheduleTarget) {
      this.scheduleTarget.innerHTML = ""
    }
  }

  finalLabel() {
    return this.hasScheduleTarget ? (this.scheduleTarget.dataset.finalLabel || "final") : "final"
  }

  fmt(n) {
    return n.toLocaleString(undefined, { minimumFractionDigits: 2, maximumFractionDigits: 2 })
  }
}
