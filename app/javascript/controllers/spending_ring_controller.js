import { Controller } from "@hotwired/stimulus";

// The month's spending ring (the Alive pass, 2026-10-18): tap a category to
// thicken its slice and read its amount in the middle; tap it again, or
// another one, to move on.
export default class extends Controller {
  static targets = ["slice", "item", "value", "label"];

  pick(event) {
    const item = event.currentTarget;
    const picked = item.getAttribute("aria-pressed") !== "true";

    for (const other of this.itemTargets)
      other.setAttribute("aria-pressed", "false");
    item.setAttribute("aria-pressed", picked ? "true" : "false");

    for (const slice of this.sliceTargets) {
      slice.setAttribute(
        "stroke-width",
        picked && slice.dataset.index === item.dataset.index ? "22" : "16",
      );
    }

    this.valueTarget.textContent = picked
      ? item.dataset.value
      : this.valueTarget.dataset.default;
    this.labelTarget.textContent = picked
      ? item.dataset.name
      : this.labelTarget.dataset.default;
  }
}
