import { Controller } from "@hotwired/stimulus";

// "Back to top" for long pages (the owner, 2026-10-18: page scrolling should
// feel modern). A small pill appears once the page has been scrolled well
// down, and takes it back to the top smoothly.
export default class extends Controller {
  static targets = ["button"];
  static values = { after: { type: Number, default: 1200 } };

  connect() {
    this.onScroll = () => this.update();
    this.element.addEventListener("scroll", this.onScroll, { passive: true });
    this.update();
  }

  disconnect() {
    this.element.removeEventListener("scroll", this.onScroll);
  }

  update() {
    if (!this.hasButtonTarget) return;
    const show = this.element.scrollTop > this.afterValue;
    this.buttonTarget.classList.toggle("opacity-0", !show);
    this.buttonTarget.classList.toggle("translate-y-3", !show);
    this.buttonTarget.classList.toggle("pointer-events-none", !show);
    this.buttonTarget.setAttribute("aria-hidden", show ? "false" : "true");
    this.buttonTarget.tabIndex = show ? 0 : -1;
  }

  top() {
    const reduce = window.matchMedia(
      "(prefers-reduced-motion: reduce)",
    ).matches;
    this.element.scrollTo({ top: 0, behavior: reduce ? "auto" : "smooth" });
  }
}
