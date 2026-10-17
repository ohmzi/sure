import { Controller } from "@hotwired/stimulus";

// The sliding pill of DS::SegmentedControl(sliding: true): one indicator sits
// under the active segment and slides to the one tapped, the iOS control. A
// link segment still navigates; the pill has moved before the page answers.
export default class extends Controller {
  static targets = ["indicator", "segment"];

  connect() {
    this.place(this.#active(), false);
    this.resizeObserver = new ResizeObserver(() =>
      this.place(this.#active(), false),
    );
    this.resizeObserver.observe(this.element);
  }

  disconnect() {
    this.resizeObserver?.disconnect();
  }

  select(event) {
    const chosen = event.currentTarget;
    for (const segment of this.segmentTargets) {
      const active = segment === chosen;
      segment.dataset.active = String(active);
      segment.classList.toggle("text-primary", active);
    }
    this.place(chosen, true);
  }

  place(segment, animate) {
    const indicator = this.indicatorTarget;
    if (!segment) {
      indicator.classList.add("opacity-0");
      return;
    }
    if (!animate) indicator.style.transition = "none";
    indicator.style.width = `${segment.offsetWidth}px`;
    indicator.style.transform = `translateX(${segment.offsetLeft}px)`;
    indicator.classList.remove("opacity-0");
    if (!animate) {
      // Commit the jump before transitions come back, so only taps animate.
      void indicator.offsetWidth;
      indicator.style.transition = "";
    }
  }

  #active() {
    return this.segmentTargets.find(
      (segment) => segment.dataset.active === "true",
    );
  }
}
