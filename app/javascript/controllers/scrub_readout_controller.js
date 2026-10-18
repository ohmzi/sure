import { Controller } from "@hotwired/stimulus";
import { rollText } from "utils/roll_number";

// The headline figure over a chart follows the point under the finger or
// pointer (the owner, 2026-10-18: "like Yahoo Finance"): the amount rolls to
// that point's value and the label shows its date; letting go rolls back to
// today. Listens for time-series-chart:scrub / :release bubbling from a chart
// inside this element.
export default class extends Controller {
  static targets = ["value", "label"];

  connect() {
    this.restingValue = this.hasValueTarget
      ? this.valueTarget.textContent.trim()
      : null;
    this.restingLabel = this.hasLabelTarget
      ? this.labelTarget.textContent.trim()
      : null;
  }

  show({ detail: { value, date } }) {
    if (this.hasValueTarget && value) rollText(this.valueTarget, value);
    if (this.hasLabelTarget && date) this.labelTarget.textContent = date;
  }

  reset() {
    if (this.hasValueTarget && this.restingValue)
      rollText(this.valueTarget, this.restingValue);
    if (this.hasLabelTarget && this.restingLabel)
      this.labelTarget.textContent = this.restingLabel;
  }
}
