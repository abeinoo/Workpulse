import { Controller } from "@hotwired/stimulus"
import { buildChartDefaults, chartPalette } from "charts/defaults"

// Branch profitability grouped bar chart, client-side sortable by metric —
// every row is already loaded, so re-sorting never needs a server round trip.
export default class extends Controller {
  static targets = [ "canvas" ]
  static values = { rows: Array, labels: Object }

  async connect() {
    // The controller stays on the wrapping card even when the empty state
    // renders instead of the canvas (no verified revenue for the period) —
    // nothing to chart in that case.
    if (!this.hasCanvasTarget) return

    const { default: Chart } = await import("chart.js/auto")
    this.Chart = Chart
    // Net profit is left out (no `net` label) when the viewer may not see
    // payroll cost for every branch in view — sort by revenue instead.
    this.render(this.labelsValue.net ? "net" : "revenue")
  }

  disconnect() {
    this.canvasTarget?.removeEventListener("click", this.#handleClick)
    this.chart?.destroy()
  }

  #handleClick = (event) => {
    const points = this.chart.getElementsAtEventForMode(event, "nearest", { intersect: true }, true)
    if (!points.length) return

    const url = this.currentUrls[points[0].index]
    if (url) Turbo.visit(url)
  }

  sort(event) {
    const key = event.currentTarget.dataset.key
    this.element.querySelectorAll("[data-action='sortable-bars#sort']").forEach((el) => {
      el.classList.toggle("is-active", el === event.currentTarget)
    })
    this.render(key)
  }

  render(key) {
    const rows = [ ...this.rowsValue ].sort((a, b) => b[key] - a[key])
    const palette = chartPalette()

    const labels = rows.map((r) => r.branch)
    this.currentUrls = rows.map((r) => r.url)
    const datasets = [
      { label: this.labelsValue.revenue, data: rows.map((r) => r.revenue), backgroundColor: palette.success },
      { label: this.labelsValue.expenses, data: rows.map((r) => r.expenses), backgroundColor: palette.danger }
    ]
    if (this.labelsValue.net) {
      datasets.push({ label: this.labelsValue.net, data: rows.map((r) => r.net), backgroundColor: palette.accent })
    }

    // Update the existing chart in place (animated re-sort) instead of
    // destroying and recreating it — same three datasets, same data.
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

    if (this.currentUrls.some((u) => u)) {
      this.canvasTarget.style.cursor = "pointer"
      this.canvasTarget.addEventListener("click", this.#handleClick)
    }

    this.element.classList.add("is-loaded")
  }
}
