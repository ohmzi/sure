import { Controller } from "@hotwired/stimulus";

// A stacked bar and its legend (the animation pass, 2026-10-18): pointing at,
// tapping or focusing a segment or its legend entry brings that part forward
// and fades the rest, so a thin bar can be read one part at a time.
export default class extends Controller {
  static targets = ["part"];

  focus(event) {
    const key = event.currentTarget.dataset.segmentKey;
    for (const part of this.partTargets) {
      part.style.opacity = part.dataset.segmentKey === key ? "" : "0.35";
    }
  }

  clear() {
    for (const part of this.partTargets) part.style.opacity = "";
  }
}
