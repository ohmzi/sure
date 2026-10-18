import { Controller } from "@hotwired/stimulus";
import { rollText } from "utils/roll_number";

// Home's net worth line, scrubbed like a stock app (the owner, 2026-10-18):
// hold and slide along it — or move a pointer over it — and the figure rolls
// to that day's net worth, the label shows the day, and a dot and guide follow
// the line. Letting go rolls back to today. A vertical swipe still scrolls the
// page (touch-action: pan-y on the track).
export default class extends Controller {
  static targets = ["track", "dot", "guide", "value", "label"];
  static values = { points: Array };

  connect() {
    this.restingValue = this.hasValueTarget
      ? this.valueTarget.textContent.trim()
      : "";
    this.restingLabel = this.hasLabelTarget
      ? this.labelTarget.textContent.trim()
      : "";
    this.restingDot = this.hasDotTarget
      ? { left: this.dotTarget.style.left, top: this.dotTarget.style.top }
      : null;
  }

  move(event) {
    if (!this.hasTrackTarget || this.pointsValue.length < 2) return;
    if (event.pointerType === "mouse" && event.type === "pointerdown") return;

    const ys = JSON.parse(this.trackTarget.dataset.ys || "[]");
    const rect = this.trackTarget.getBoundingClientRect();
    const fraction = Math.min(
      1,
      Math.max(0, (event.clientX - rect.left) / rect.width),
    );
    const index = Math.round(fraction * (this.pointsValue.length - 1));
    const point = this.pointsValue[index];
    const x = (index / (this.pointsValue.length - 1)) * 100;

    if (this.hasDotTarget) {
      this.dotTarget.style.left = `clamp(9px, ${x}%, calc(100% - 9px))`;
      if (ys[index] !== undefined)
        this.dotTarget.style.top = `${(ys[index] / 40) * 100}%`;
    }
    if (this.hasGuideTarget) {
      this.guideTarget.classList.remove("hidden");
      this.guideTarget.style.left = `${x}%`;
    }
    if (this.hasValueTarget && point?.value)
      rollText(this.valueTarget, point.value);
    if (this.hasLabelTarget && point?.label)
      this.labelTarget.textContent = point.label;
    this.scrubbing = true;
  }

  // A finger lifting ends the scrub; a mouse button does not (it hovers on).
  lift(event) {
    if (event.pointerType !== "mouse") this.end();
  }

  end() {
    if (!this.scrubbing) return;
    this.scrubbing = false;

    if (this.hasDotTarget && this.restingDot)
      Object.assign(this.dotTarget.style, this.restingDot);
    if (this.hasGuideTarget) this.guideTarget.classList.add("hidden");
    if (this.hasValueTarget) rollText(this.valueTarget, this.restingValue);
    if (this.hasLabelTarget) this.labelTarget.textContent = this.restingLabel;
  }
}
