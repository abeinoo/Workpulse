import { Controller } from "@hotwired/stimulus"
import { buildChartDefaults, chartPalette } from "charts/defaults"

// Revenue / Expenses / Net line chart with a client-side Monthly / Quarterly /
// Yearly grouping toggle. The server always supplies monthly data (revenue is
// only ever entered at month granularity) — grouping to quarter/year is a
// pure client-side reduction of that same data, not a new calculation.
export default class extends Controller {
  static targets = [ "canvas", "option" ]

  static values = {
    labels: Array,
    revenue: Array,
    expenses: Array,
    net: Array,
    labelsRevenue: String,
    labelsExpenses: String,
    labelsNet: String,
    urls: { type: Array, default: [] }
  }

  async connect() {
    // The controller stays on the wrapping card even when the empty state
    // renders instead of the canvas (no financial activity for the period).
    if (!this.hasCanvasTarget) return

    const { default: Chart } = await import("chart.js/auto")
    this.Chart = Chart
    this.render("month")

    if (this.urlsValue.length) {
      this.canvasTarget.addEventListener("click", this.#handleClick)
    }
  }

  disconnect() {
    this.canvasTarget?.removeEventListener("click", this.#handleClick)
    this.chart?.destroy()
  }

  // Drill-down only makes sense at month granularity — a quarter/year bar is
  // a client-side sum of several months, not one dashboard filter range.
  #handleClick = (event) => {
    if (this.currentGroup !== "month") return

    // "index" + intersect:false — same interaction mode buildChartDefaults()
    // already uses for hover (crosshair-style), so a click anywhere along a
    // month's x-position hits it. A line point's own hit radius is only 8px
    // (radius:0 normally), too thin a target for "nearest"+intersect:true.
    const points = this.chart.getElementsAtEventForMode(event, "index", { intersect: false }, true)
    if (!points.length) return

    const url = this.urlsValue[points[0].index]
    if (url) Turbo.visit(url)
  }

  group(event) {
    const group = event.currentTarget.dataset.group
    this.optionTargets.forEach((el) => el.classList.toggle("is-active", el === event.currentTarget))
    this.render(group)
  }

  render(group) {
    this.currentGroup = group
    if (this.urlsValue.length) {
      this.canvasTarget.style.cursor = group === "month" ? "pointer" : "default"
    }

    const { labels, revenue, expenses, net } = this.#aggregate(group)
    const palette = chartPalette()

    // Revenue/Net are omitted server-side (empty array) for users without
    // view_expense_reports — only render the series that actually have data.
    const datasets = [
      { label: this.labelsExpensesValue, data: expenses, borderColor: palette.danger, backgroundColor: palette.dangerMuted, tension: 0.3 }
    ]
    if (this.revenueValue.length) {
      datasets.unshift({ label: this.labelsRevenueValue, data: revenue, borderColor: palette.success, backgroundColor: palette.successMuted, tension: 0.3 })
    }
    if (this.netValue.length) {
      datasets.push({ label: this.labelsNetValue, data: net, borderColor: palette.accent, backgroundColor: palette.accentMuted, borderDash: [ 5, 4 ], tension: 0.3 })
    }

    // Update the existing chart in place (smooth animated transition between
    // Monthly/Quarterly/Yearly) instead of destroying and recreating it —
    // same data, same calculation, just a nicer transition.
    if (this.chart) {
      this.chart.data.labels = labels
      this.chart.data.datasets = datasets
      this.chart.update()
      return
    }

    this.chart = new this.Chart(this.canvasTarget, {
      type: "line",
      data: { labels, datasets },
      options: buildChartDefaults()
    })

    this.element.classList.add("is-loaded")
  }

  #aggregate(group) {
    if (group === "month") {
      return { labels: this.labelsValue, revenue: this.revenueValue, expenses: this.expensesValue, net: this.netValue }
    }

    const size = group === "quarter" ? 3 : 12
    const labels = [], revenue = [], expenses = [], net = []

    for (let i = 0; i < this.labelsValue.length; i += size) {
      const slice = (arr) => arr.slice(i, i + size).reduce((a, b) => a + b, 0)
      const monthLabels = this.labelsValue.slice(i, i + size)
      labels.push(group === "quarter" ? monthLabels[0] : monthLabels[0]?.split(" ")[1])
      revenue.push(slice(this.revenueValue))
      expenses.push(slice(this.expensesValue))
      net.push(slice(this.netValue))
    }

    return { labels, revenue, expenses, net }
  }
}
