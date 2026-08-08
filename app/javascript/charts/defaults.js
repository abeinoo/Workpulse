// Shared Chart.js configuration for every analytical chart in the app.
// Reads the app's CSS custom properties so chart colors always track the
// active theme (light/dark) and stay in sync with .stat-card / badge colors.

function cssVar(name, fallback) {
  const value = getComputedStyle(document.documentElement).getPropertyValue(name).trim()
  return value || fallback
}

function rgbaFromChannel(channelVar, alpha, fallback) {
  const channel = cssVar(channelVar, fallback)
  return `rgba(${channel}, ${alpha})`
}

export function chartPalette() {
  return {
    accent:  cssVar("--accent", "#0276AE"),
    success: cssVar("--success", "#047857"),
    danger:  cssVar("--danger", "#DC2626"),
    warning: cssVar("--warning", "#B45309"),
    indigo:  cssVar("--indigo", "#6366F1"),
    accentMuted:  rgbaFromChannel("--accent-rgb", 0.16, "2, 118, 174"),
    successMuted: rgbaFromChannel("--success-rgb", 0.16, "16, 185, 129"),
    dangerMuted:  rgbaFromChannel("--danger-rgb", 0.16, "239, 68, 68"),
    warningMuted: rgbaFromChannel("--warning-rgb", 0.16, "245, 158, 11"),
    text1:   cssVar("--text-1", "#0F2540"),
    text2:   cssVar("--text-2", "#4B5A70"),
    text3:   cssVar("--text-3", "#6B7687"),
    border:  cssVar("--border", "#E2E8F0"),
    surface: cssVar("--surface-1", "#FFFFFF")
  }
}

// A rotating series palette for multi-slice charts (pie/doughnut/multi-bar).
export function seriesColors() {
  const p = chartPalette()
  return [ p.accent, p.success, p.warning, p.danger, p.indigo, p.text3 ]
}

// Deterministic color-per-label (e.g. per branch) so the same branch always
// gets the same color across every widget/chart type/re-sort, instead of a
// color that shifts with array order.
export function colorForLabel(label) {
  const palette = seriesColors()
  let hash = 0
  for (let i = 0; i < label.length; i++) hash = (hash * 31 + label.charCodeAt(i)) >>> 0
  return palette[hash % palette.length]
}

export function isRtl() {
  return document.documentElement.getAttribute("dir") === "rtl"
}

// Shared "150,000" style thousands-separator formatting for tooltip values —
// display-only number formatting, not a financial calculation. Doughnut/pie
// charts override this with their own percentage-of-total callback (see
// chart_controller.js#mergeOptions), so this only ever applies to bar/line.
function formatTooltipValue(value) {
  const num = Number(value)
  return Number.isFinite(num) ? num.toLocaleString(isRtl() ? "ar" : "en") : value
}

export function buildChartDefaults() {
  const p = chartPalette()
  const rtl = isRtl()

  return {
    responsive: true,
    maintainAspectRatio: false,
    resizeDelay: 100,
    interaction: { mode: "index", intersect: false },
    locale: rtl ? "ar" : "en",
    color: p.text2,
    borderColor: p.border,
    font: { family: getComputedStyle(document.body).fontFamily || "sans-serif" },
    animation: { duration: 650, easing: "easeOutQuart" },
    plugins: {
      legend: {
        rtl,
        textDirection: rtl ? "rtl" : "ltr",
        labels: { color: p.text2, usePointStyle: true, pointStyle: "circle", boxWidth: 8, boxHeight: 8, padding: 18, font: { size: 12, weight: "600" } }
      },
      tooltip: {
        rtl,
        textDirection: rtl ? "rtl" : "ltr",
        backgroundColor: p.surface,
        titleColor: p.text1,
        titleFont: { weight: "700" },
        bodyColor: p.text2,
        borderColor: p.border,
        borderWidth: 1,
        padding: 12,
        boxPadding: 6,
        cornerRadius: 8,
        callbacks: { label: (ctx) => ` ${ctx.dataset.label ? ctx.dataset.label + ": " : ""}${formatTooltipValue(ctx.parsed.y ?? ctx.parsed)}` }
      }
    },
    scales: {
      x: {
        grid: { display: false },
        ticks: { color: p.text3, font: { size: 11 } },
        reverse: rtl
      },
      y: {
        grid: { color: p.border },
        ticks: { color: p.text3, font: { size: 11 } },
        position: rtl ? "right" : "left"
      }
    },
    elements: {
      point: { radius: 0, hoverRadius: 5, hoverBorderWidth: 2, hitRadius: 8 },
      line: { borderWidth: 2.5 },
      bar: { borderRadius: 4, borderSkipped: false }
    }
  }
}
