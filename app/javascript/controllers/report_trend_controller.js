import { Controller } from "@hotwired/stimulus"
import { buildChartDefaults, chartPalette } from "charts/defaults"

// Single-series expense trend with a Monthly/Quarterly/Yearly toggle and a
// moving-average overlay — same client-side re-bucketing approach as the
// Finance Dashboard's trend-chart controller (sum the already-computed
// monthly figures into coarser buckets; no new calculation, no new query).
export default class extends Controller {
  static targets = [ "canvas", "option" ]

  static values = {
    labels: Array,
    actual: Array,
    movingAverage: Array,
    labelActual: String,
    labelMovingAverage: String
  }

  async connect() {
    // The controller stays on the wrapping card even when the empty state
    // renders instead of the canvas (no expense data for the period).
    if (!this.hasCanvasTarget) return

    const { default: Chart } = await import("chart.js/auto")
    this.Chart = Chart
    this.render("month")
  }

  disconnect() {
    this.chart?.destroy()
  }

  group(event) {
    const group = event.currentTarget.dataset.group
    this.optionTargets.forEach((el) => el.classList.toggle("is-active", el === event.currentTarget))
    this.render(group)
  }

  render(group) {
    const { labels, actual, movingAverage } = this.#aggregate(group)
    const palette = chartPalette()

    const datasets = [
      { label: this.labelActualValue, data: actual, borderColor: palette.accent, backgroundColor: palette.accentMuted, tension: 0.3, fill: true },
      { label: this.labelMovingAverageValue, data: movingAverage, borderColor: palette.warning, backgroundColor: "transparent", borderDash: [ 5, 4 ], tension: 0.3, fill: false }
    ]

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
      return { labels: this.labelsValue, actual: this.actualValue, movingAverage: this.movingAverageValue }
    }

    const size = group === "quarter" ? 3 : 12
    const labels = [], actual = [], movingAverage = []

    for (let i = 0; i < this.labelsValue.length; i += size) {
      const slice = (arr) => arr.slice(i, i + size).reduce((a, b) => a + b, 0)
      const monthLabels = this.labelsValue.slice(i, i + size)
      labels.push(group === "quarter" ? monthLabels[0] : monthLabels[0]?.split(" ")[1])
      actual.push(slice(this.actualValue))
      movingAverage.push(slice(this.movingAverageValue))
    }

    return { labels, actual, movingAverage }
  }
}
