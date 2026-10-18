import { Controller } from "@hotwired/stimulus";

// Point at one part of a small chart — a bar segment or its legend entry —
// and every item sharing its key stays lit while the rest dim (the animation
// pass, 2026-10-18). Items carry `data-key`; give them a transition-opacity.
// Pointer events cover a mouse, a pen and a finger alike.
export default class extends Controller {
  static targets = ["item"];

  enter(event) {
    const key = event.currentTarget.dataset.key;
    for (const item of this.itemTargets) {
      item.classList.toggle("opacity-40", item.dataset.key !== key);
    }
  }

  leave() {
    for (const item of this.itemTargets) item.classList.remove("opacity-40");
  }
}
