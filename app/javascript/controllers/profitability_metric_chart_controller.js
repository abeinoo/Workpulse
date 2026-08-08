import { Controller } from "@hotwired/stimulus"
import { buildChartDefaults, chartPalette } from "charts/defaults"

// Branch Profitability flagship chart: switches between five metrics
// (net/revenue/expenses/payroll/inventory), each rendered as current-vs-
// previous-period grouped bars for every branch. All values come from rows
// already computed server-side (Finance::Reports::BranchProfitability +
// VerifiedRevenue) — this controller only re-shapes and re-sorts them.
export default class extends Controller {
  static targets = [ "canvas", "option" ]
  static values = { rows: Array, metricLabels: Object, currentLabel: String, previousLabel: String }

  async connect() {
    // The empty state renders instead of the canvas when there are no
    // branches to chart for this business.
    if (!this.hasCanvasTarget) return

    const { default: Chart } = await import("chart.js/auto")
    this.Chart = Chart
    this.render("net")
  }

  disconnect() {
    this.chart?.destroy()
  }

  switch(event) {
    const metric = event.currentTarget.dataset.metric
    this.optionTargets.forEach((el) => el.classList.toggle("is-active", el === event.currentTarget))
    this.render(metric)
  }

  render(metric) {
    const rows = [ ...this.rowsValue ].sort((a, b) => b[metric] - a[metric])
    const palette = chartPalette()

    const labels = rows.map((r) => r.branch)
    this.currentUrls = rows.map((r) => r.url)

    const datasets = [
      { label: this.currentLabelValue, data: rows.map((r) => r[metric]), backgroundColor: palette.accent },
      { label: this.previousLabelValue, data: rows.map((r) => r.previous[metric]), backgroundColor: palette.border }
    ]

    if (this.chart) {
      this.chart.data.labels = labels
      this.chart.data.datasets = datasets
      this.chart.update()
      return
    }

    this.chart = new this.Chart(this.canvasTarget, {
      type: "bar",
      data: { labels, datasets },
      options: buildChartDefaults()
    })

    this.canvasTarget.style.cursor = "pointer"
    this.canvasTarget.addEventListener("click", this.#handleClick)
    this.element.classList.add("is-loaded")
  }

  #handleClick = (event) => {
    const points = this.chart.getElementsAtEventForMode(event, "nearest", { intersect: true }, true)
    if (!points.length) return

    const url = this.currentUrls[points[0].index]
    if (url) Turbo.visit(url)
  }
}
