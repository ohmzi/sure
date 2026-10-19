import { Controller } from "@hotwired/stimulus";
import { rollText } from "utils/roll_number";

// The headline figure over a chart follows the point under the finger or
// pointer (the owner, 2026-10-18: "like Yahoo Finance"): the amount rolls to
// that point's value and the label shows its date; letting go rolls back to
// today. Listens for a chart's :scrub / :release events bubbling from inside
// this element (time-series-chart, spending-chart, bar-chart).
//
// Targets, all optional:
//   value    the main figure (detail.value)
//   compare  a second figure, such as last month's (detail.compare)
//   label    the date or period name (detail.date)
//   hide     anything that does not apply to the point, such as a change
//            against the period; faded out while scrubbing
//   field    a named figure (data-scrub-field="income") read from
//            detail.fields; with data-scrub-tone it also takes the colour of
//            detail.tones[name] ("positive", "negative" or "zero")
const TONES = {
  positive: "text-success",
  negative: "text-destructive",
  zero: "text-primary",
};

export default class extends Controller {
  static targets = ["value", "compare", "label", "hide", "field"];

  connect() {
    this.resting = new Map();
    for (const target of [
      ...this.valueTargets,
      ...this.compareTargets,
      ...this.labelTargets,
      ...this.fieldTargets,
    ])
      this.resting.set(target, target.textContent.trim());
    this.restingClass = new Map(
      this.fieldTargets.map((target) => [target, target.className]),
    );
  }

  show({ detail: { value, compare, date, fields = {}, tones = {} } }) {
    for (const target of this.fieldTargets) {
      const name = target.dataset.scrubField;
      if (fields[name]) rollText(target, fields[name]);
      if ("scrubTone" in target.dataset && tones[name]) {
        target.classList.remove(...Object.values(TONES));
        target.classList.add(TONES[tones[name]]);
      }
    }
    for (const target of this.valueTargets) if (value) rollText(target, value);
    for (const target of this.compareTargets)
      if (compare) rollText(target, compare);
    for (const target of this.labelTargets) if (date) target.textContent = date;
    for (const target of this.hideTargets) target.classList.add("opacity-0");
  }

  reset() {
    for (const target of [
      ...this.valueTargets,
      ...this.compareTargets,
      ...this.fieldTargets,
    ])
      rollText(target, this.resting.get(target));
    for (const target of this.fieldTargets)
      target.className = this.restingClass.get(target);
    for (const target of this.labelTargets)
      target.textContent = this.resting.get(target);
    for (const target of this.hideTargets) target.classList.remove("opacity-0");
  }
}
