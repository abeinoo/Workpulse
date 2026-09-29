import { Controller } from "@hotwired/stimulus"
import { buildChartDefaults, seriesColors, colorForLabel, chartPalette, isRtl } from "charts/defaults"

// Generic Chart.js wrapper. Usage:
//
//   <canvas data-controller="chart"
//           data-chart-type-value="line"
//           data-chart-data-value="<%= chart_data.to_json %>"
//           data-chart-options-value="<%= chart_options.to_json %>"
//           data-chart-link-prefix-value="<%= finance_expenses_path %>"></canvas>
//
// `data-value` follows the Chart.js `data` shape ({ labels, datasets }).
// Segment/bar clicks navigate to `linkPrefixValue + label` via Turbo when a
// dataset point has a matching entry in the optional `links` array.
export default class extends Controller {
  static values = {
    type: String,
    data: Object,
    options: { type: Object, default: {} },
    links: { type: Array, default: [] },
    // One measure per category (e.g. consumption by branch): every bar in
    // the theme accent instead of a color per bar — color then carries no
    // (false) identity, and no legend is needed.
    singleHue: { type: Boolean, default: false }
  }

  async connect() {
    const { default: Chart } = await import("chart.js/auto")
    this.Chart = Chart

    const defaults = buildChartDefaults()
    const data = this.#applyPalette(this.dataValue)

    this.chart = new Chart(this.element, {
      type: this.typeValue,
      data,
      options: this.#mergeOptions(defaults, this.optionsValue)
    })

    // Swap the loading skeleton for the fully-rendered canvas (see
    // .chart-card:not(.is-loaded) in application.css) — fires once the
    // chart instance exists, whether or not it has finished animating in.
    this.element.closest(".chart-card")?.classList.add("is-loaded")

    if (this.linksValue.length) {
      this.element.style.cursor = "pointer"
      this.element.addEventListener("click", this.#handleClick)
    }
  }

  disconnect() {
    this.element.removeEventListener("click", this.#handleClick)
    this.chart?.destroy()
  }

  #handleClick = (event) => {
    const points = this.chart.getElementsAtEventForMode(event, "nearest", { intersect: true }, true)
    if (!points.length) return

    const url = this.linksValue[points[0].index]
    if (url) Turbo.visit(url)
  }

  #isDonutLike() {
    return this.typeValue === "pie" || this.typeValue === "doughnut"
  }

  // Only chart types where each data point is its own visual segment (pie
  // slice / doughnut slice / individual bar) should get an array of colors.
  // A line's backgroundColor/borderColor must stay a single color — an
  // array there produces an invalid fill/stroke, not a color-per-point line.
  #isPerPointColored() {
    return this.#isDonutLike() || this.typeValue === "bar"
  }

  #applyPalette(data) {
    if (!data.datasets) return data

    const palette = seriesColors()
    // Doughnut/pie slices get a color derived from their own label (stable
    // across re-filters/re-sorts) instead of array-index rotation, so e.g.
    // a given branch is always the same color everywhere it appears.
    const sliceColors = this.#isDonutLike() && data.labels ? data.labels.map(colorForLabel) : palette
    const perPoint = this.#isPerPointColored() && !this.singleHueValue

    data.datasets = data.datasets.map((dataset, i) => ({
      backgroundColor: dataset.backgroundColor || (perPoint && Array.isArray(dataset.data) && dataset.data.length > 1 ? sliceColors : palette[i % palette.length]),
      borderColor: dataset.borderColor || (this.#isDonutLike() ? chartPalette().surface : palette[i % palette.length]),
      ...dataset
    }))
    return data
  }

  #mergeOptions(defaults, overrides) {
    const donut = this.#isDonutLike()
    const rtl = isRtl()

    return {
      ...defaults,
      ...overrides,
      cutout: donut ? "62%" : undefined,
      borderWidth: donut ? 2 : undefined,
      hoverOffset: donut ? 6 : undefined,
      plugins: {
        ...defaults.plugins,
        ...overrides.plugins,
        legend: donut
          ? { ...defaults.plugins.legend, position: rtl ? "left" : "right", align: "center" }
          : { ...defaults.plugins.legend, ...overrides.plugins?.legend },
        tooltip: {
          ...defaults.plugins.tooltip,
          ...overrides.plugins?.tooltip,
          callbacks: donut ? {
            label: (ctx) => {
              const total = ctx.dataset.data.reduce((sum, v) => sum + Number(v), 0)
              const pct = total ? (Number(ctx.parsed) / total * 100).toFixed(1) : 0
              return ` ${ctx.label}: ${ctx.formattedValue} (${pct}%)`
            }
          } : (overrides.plugins?.tooltip?.callbacks || defaults.plugins.tooltip.callbacks)
        }
      },
      scales: donut ? undefined : { ...defaults.scales, ...overrides.scales }
    }
  }
}
