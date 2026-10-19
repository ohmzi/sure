import { Controller } from "@hotwired/stimulus";
import * as d3 from "d3";
import { CHART_TOOLTIP_CLASSES } from "utils/chart_tooltip";
import { revealOnView } from "utils/reveal_on_view";

// Grouped bar chart used by the dashboard "money flow" widget — each month
// shows an expense bar (red) and an income bar (green) side by side.
// Modeled after time_series_chart_controller's lifecycle (install/teardown,
// ResizeObserver, turbo:load reinstall, page-relative tooltip positioning)
// but with scaleBand/scaleLinear instead of a line.

// Breathing room between neighbouring month labels before they read as touching.
const LABEL_GAP_PX = 8;

export default class extends Controller {
  static values = {
    data: Array,
    currency: { type: String, default: "USD" },
    incomeLabel: { type: String, default: "Income" },
    expenseLabel: { type: String, default: "Expenses" },
  };

  _resizeObserver = null;

  connect() {
    // Shimmers until scrolled into view, then plays its entrance (2026-10-18).
    this.stopReveal = revealOnView(this.element);
    this._install();
    document.addEventListener("turbo:load", this._reinstall);
    this._resizeObserver = new ResizeObserver(() => this._reinstall());
    this._resizeObserver.observe(this.element);
  }

  disconnect() {
    this.stopReveal?.();
    this._teardown();
    document.removeEventListener("turbo:load", this._reinstall);
    this._resizeObserver?.disconnect();
  }

  _reinstall = () => {
    this._teardown();
    this._install();
  };

  _teardown() {
    d3.select(this.element).selectAll("*").remove();
  }

  _install() {
    const width = this.element.clientWidth;
    const height = this.element.clientHeight;
    const data = this.dataValue || [];

    if (width < 50 || height < 50 || data.length === 0) return;

    const margin = { top: 16, right: 4, bottom: 24, left: 4 };
    const innerWidth = width - margin.left - margin.right;
    const innerHeight = height - margin.top - margin.bottom;

    const svg = d3
      .select(this.element)
      .append("svg")
      .attr("width", width)
      .attr("height", height)
      .attr("viewBox", [0, 0, width, height]);

    const group = svg
      .append("g")
      .attr("transform", `translate(${margin.left},${margin.top})`);

    const series = ["income", "expense"];
    const seriesColor = {
      expense: "var(--color-gray-400)",
      income: "var(--color-success)",
    };

    const x0 = d3
      .scaleBand()
      .domain(data.map((d) => d.label))
      .range([0, innerWidth])
      .padding(0.3);

    const x1 = d3
      .scaleBand()
      .domain(series)
      .range([0, x0.bandwidth()])
      .padding(0.15);

    const maxValue = d3.max(data, (d) => Math.max(d.income, d.expense)) || 1;
    const y = d3
      .scaleLinear()
      .domain([0, maxValue * 1.1])
      .range([innerHeight, 0]);
    // Floor tiny-but-nonzero bars (e.g. an in-progress month) at 2px so they stay visible.
    const barHeight = (v) => (v > 0 ? Math.max(2, innerHeight - y(v)) : 0);

    const tooltip = d3
      .select(this.element)
      .append("div")
      .attr("class", `${CHART_TOOLTIP_CLASSES} opacity-0 top-0`);

    const showTooltip = (event, month, key) => {
      const estimatedTooltipWidth = 200;
      const pageWidth = document.body.clientWidth;
      const tooltipX = event.pageX + 10;
      const overflowX = tooltipX + estimatedTooltipWidth - pageWidth;
      const adjustedX = overflowX > 0 ? event.pageX - overflowX - 20 : tooltipX;

      tooltip
        .html(this._tooltipTemplate(month, key))
        .style("opacity", 1)
        .style("left", `${adjustedX}px`)
        .style("top", `${event.pageY - 10}px`);
    };

    const hideTooltip = () => tooltip.style("opacity", 0);

    const monthGroups = group
      .selectAll("g.month")
      .data(data)
      .join("g")
      .attr("class", "month")
      .attr("transform", (d) => `translate(${x0(d.label)},0)`);

    const bars = monthGroups
      .selectAll("rect")
      .data((d) => series.map((key) => ({ key, value: d[key], month: d })))
      .join("rect")
      .attr("x", (d) => x1(d.key))
      .attr("y", (d) => innerHeight - barHeight(d.value))
      .attr("width", x1.bandwidth())
      .attr("height", (d) => barHeight(d.value))
      .attr("rx", 3)
      // Bars grow up from the baseline on first draw, month by month (the
      // animation pass, 2026-10-18).
      .attr("class", "grow-up")
      .style(
        "animation-delay",
        (d) => `${Math.min(data.indexOf(d.month), 12) * 35}ms`,
      )
      .attr("fill", (d) => seriesColor[d.key])
      // In-progress month (period capped at today) reads as provisional.
      .attr("fill-opacity", (d) => (d.month.partial ? 0.5 : 1))
      .style("cursor", "pointer")
      .style("transition", "opacity 160ms ease");

    // The month under the pointer stays bright and the rest dim (the
    // animation pass, 2026-10-18). A finger slides across the months, the
    // way a stock app scrubs, and the summary beside the chart follows the
    // month under it (scrub_readout_controller); a mouse also gets the
    // value of the bar it is on. Lifting the finger clears it all, so no
    // reading floats over the page (the owner, 2026-10-18). Phones read
    // touch-action from the chart's own box, not from shapes in its SVG.
    d3.select(this.element)
      .style("touch-action", "pan-y")
      .style("user-select", "none")
      .style("-webkit-touch-callout", "none");

    const highlight = (month) =>
      bars.style("opacity", (d) => (month && d.month !== month ? 0.4 : null));

    const monthAt = (event) => {
      const [xPos] = d3.pointer(event, group.node());
      const index = Math.floor(
        (xPos - x0.step() * x0.paddingOuter()) / x0.step(),
      );
      return data[Math.max(0, Math.min(index, data.length - 1))];
    };

    let scrubbed = null;
    const scrub = (event) => {
      const month = monthAt(event);
      highlight(month);
      if (event.pointerType === "mouse" && event.target.tagName === "rect") {
        const d = d3.select(event.target).datum();
        showTooltip(event, d.month, d.key);
      } else {
        hideTooltip();
      }
      if (month === scrubbed) return;
      scrubbed = month;
      const balance = month.income - month.expense;
      this.dispatch("scrub", {
        detail: {
          date: month.full_label ?? month.label,
          fields: {
            income: this._formatCurrency(month.income, 2),
            expense: this._formatCurrency(month.expense, 2),
            balance: this._formatCurrency(balance, 2),
          },
          tones: {
            balance:
              balance < 0 ? "negative" : balance > 0 ? "positive" : "zero",
          },
        },
      });
    };

    const release = () => {
      scrubbed = null;
      highlight(null);
      hideTooltip();
      this.dispatch("release");
    };

    svg
      .on("pointerdown pointermove", scrub)
      .on("pointerleave pointercancel", release)
      .on("pointerup", (event) => {
        if (event.pointerType !== "mouse") release();
      });

    const axisLabels = group
      .append("g")
      .attr("transform", `translate(0,${innerHeight})`)
      .call(d3.axisBottom(x0).tickSize(0))
      .call((g) => g.select(".domain").remove())
      .selectAll("text")
      .attr("class", (_d, i) =>
        data[i].highlighted
          ? "text-primary fill-current"
          : "text-secondary fill-current",
      )
      .style("font-size", "12px")
      .style("font-weight", (_d, i) => (data[i].highlighted ? 600 : 500));

    this._fitAxisLabels(axisLabels, data, x0.step());
  }

  // The month labels are sized by the locale, not by the chart: "Mar 2026" fits
  // a phone, "Mar de 2026" (ca/es/pt) does not and overlaps its neighbours.
  // Measure what actually rendered and step down until it fits — full label,
  // then the abbreviated month, then every other tick. Measuring beats guessing
  // at a character width, which varies by locale, font and zoom.
  _fitAxisLabels(labels, data, step) {
    if (labels.empty()) return;

    const widest = () =>
      d3.max(labels.nodes(), (node) => node.getComputedTextLength()) || 0;
    const fits = () => widest() <= step - LABEL_GAP_PX;

    if (fits()) return;

    labels.text((_d, i) => data[i].short_label ?? data[i].label);
    if (fits()) return;

    // Still too wide (a very narrow column): thin out rather than overlap.
    // The parity is taken from the highlighted month rather than fixed at even,
    // so that month survives without being an exception to the pattern — it
    // sits last (build_money_flow_data counts down to the selected month), and
    // keeping it on top of every even index left the final two labels one step
    // apart, the very spacing that had just been measured as too tight.
    const highlightedIndex = data.findIndex((d) => d.highlighted);
    const keepParity = highlightedIndex >= 0 ? highlightedIndex % 2 : 0;
    labels.style("display", (_d, i) => (i % 2 === keepParity ? null : "none"));
  }

  _tooltipTemplate(month, key) {
    const label =
      key === "income" ? this.incomeLabelValue : this.expenseLabelValue;
    // Match the bar/legend palette — expenses render gray, not destructive red.
    const color =
      key === "income" ? "var(--color-success)" : "var(--color-gray-400)";

    return `
      <div class="text-xs text-secondary mb-1">${month.label}</div>
      <div class="flex items-center gap-1.5 text-primary font-medium tabular-nums">
        <span class="inline-block w-2 h-2 rounded-full" style="background-color: ${color};"></span>
        ${label}: ${this._formatCurrency(month[key])}
      </div>
    `;
  }

  _formatCurrency(value, fractionDigits = 0) {
    try {
      return new Intl.NumberFormat(undefined, {
        style: "currency",
        currency: this.currencyValue,
        minimumFractionDigits: fractionDigits,
        maximumFractionDigits: fractionDigits,
      }).format(value);
    } catch {
      return value;
    }
  }
}
