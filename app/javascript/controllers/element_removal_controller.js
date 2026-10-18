import { Controller } from "@hotwired/stimulus";

// Connects to data-controller="element-removal"
//
// Removes the element with a short fade (the animation pass, 2026-10-18). With
// an `animation` value it only answers the animation of that name ending, so
// the element's own entrance (pop-in) cannot dismiss it.
export default class extends Controller {
  static values = { animation: String };

  remove(event) {
    if (
      this.hasAnimationValue &&
      event?.type === "animationend" &&
      event.animationName !== this.animationValue
    )
      return;
    if (this.removing) return;
    this.removing = true;

    if (
      window.matchMedia("(prefers-reduced-motion: reduce)").matches ||
      !this.element.animate
    ) {
      this.element.remove();
      return;
    }

    this.element
      .animate(
        [
          { opacity: 1, transform: "none" },
          { opacity: 0, transform: "translateY(-6px) scale(0.98)" },
        ],
        {
          duration: 180,
          easing: "ease-in",
          fill: "forwards",
        },
      )
      .finished.then(() => this.element.remove())
      .catch(() => this.element.remove());
  }
}
