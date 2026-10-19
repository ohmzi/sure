import { Controller } from "@hotwired/stimulus";
import { rollText } from "utils/roll_number";
import { scrubIntent } from "utils/scrub_intent";

// Home's net worth line, scrubbed like a stock app (the owner, 2026-10-18):
// hold and slide along it — or move a pointer over it — and the figure rolls
// to that day's net worth, the label shows the day, and a dot and guide follow
// the line. Letting go rolls back to today. A vertical swipe still scrolls the
// page (touch-action: pan-y on the track), and shows nothing (scrub_intent).
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
    this.intent = scrubIntent({ onStart: (event) => this.#scrubTo(event) });
  }

  move(event) {
    if (!this.hasTrackTarget || this.pointsValue.length < 2) return;
    if (event.type === "pointerdown") {
      // A mouse press is not a scrub; it hovers already.
      if (event.pointerType === "mouse") return;
      // The finger stays with the track wherever it goes, so its lift always
      // arrives here (the owner, 2026-10-19: a fast finger left the figure
      // stuck on a day).
      this.trackTarget.setPointerCapture?.(event.pointerId);
      if (this.intent.down(event)) this.#scrubTo(event);
      return;
    }
    if (this.intent.move(event)) this.#scrubTo(event);
  }

  disconnect() {
    this.#stopWatchingRelease();
  }

  // A finger lifting ends the scrub; a mouse button does not (it hovers on).
  lift(event) {
    if (event.pointerType !== "mouse") this.end();
  }

  end() {
    this.intent.end();
    this.#stopWatchingRelease();
    if (!this.scrubbing) return;
    this.scrubbing = false;

    // Today's point comes back where it lives, with a small pop, rather than
    // sliding there from wherever the finger let go (the owner, 2026-10-18:
    // it "moves from above down").
    if (this.hasDotTarget && this.restingDot) {
      const dot = this.dotTarget;
      dot.style.transition = "none";
      Object.assign(dot.style, this.restingDot);
      dot.getBoundingClientRect();
      dot.style.transition = "";
      if (!window.matchMedia("(prefers-reduced-motion: reduce)").matches)
        dot.animate(
          [
            { scale: "0.3", opacity: 0 },
            { scale: "1", opacity: 1 },
          ],
          { duration: 220, easing: "cubic-bezier(0.2, 0.9, 0.25, 1)" },
        );
    }
    if (this.hasGuideTarget) this.guideTarget.classList.add("hidden");
    if (this.hasValueTarget) rollText(this.valueTarget, this.restingValue);
    if (this.hasLabelTarget) this.labelTarget.textContent = this.restingLabel;
  }

  // Any finger lifted anywhere ends the scrub, as a safety net under the
  // pointer capture above.
  #watchRelease() {
    this.#stopWatchingRelease();
    this.releaseHandler = (event) => {
      if (event.pointerType !== "mouse") this.end();
    };
    window.addEventListener("pointerup", this.releaseHandler, true);
    window.addEventListener("pointercancel", this.releaseHandler, true);
  }

  #stopWatchingRelease() {
    if (!this.releaseHandler) return;
    window.removeEventListener("pointerup", this.releaseHandler, true);
    window.removeEventListener("pointercancel", this.releaseHandler, true);
    this.releaseHandler = null;
  }

  #scrubTo(event) {
    const ys = JSON.parse(this.trackTarget.dataset.ys || "[]");
    const rect = this.trackTarget.getBoundingClientRect();
    const fraction = Math.min(
      1,
      Math.max(0, (event.clientX - rect.left) / rect.width),
    );
    const index = Math.round(fraction * (this.pointsValue.length - 1));
    const point = this.pointsValue[index];
    const x = (index / (this.pointsValue.length - 1)) * 100;

    if (!this.scrubbing) this.#watchRelease();
    if (this.hasDotTarget) {
      // The dot sits on the line at once; easing it there left it trailing
      // above or below the line under a fast finger.
      this.dotTarget.style.transition = "none";
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
}
