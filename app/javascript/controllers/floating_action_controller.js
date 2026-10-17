import { Controller } from "@hotwired/stimulus";

// Keeps a floating action button over the main content's bottom-right corner,
// not the window's: on a computer the assistant sidebar sits to the right of
// #main, and the button must never cover it. Phones have no sidebar, so this
// lands on the screen edge there.
export default class extends Controller {
  connect() {
    this.main = document.getElementById("main");
    if (!this.main) return;
    this.place = this.place.bind(this);
    this.resizeObserver = new ResizeObserver(this.place);
    this.resizeObserver.observe(this.main);
    window.addEventListener("resize", this.place);
    this.place();
  }

  disconnect() {
    this.resizeObserver?.disconnect();
    window.removeEventListener("resize", this.place);
  }

  place() {
    const gutter = window.matchMedia("(min-width: 1024px)").matches ? 32 : 16;
    const right =
      document.documentElement.clientWidth -
      this.main.getBoundingClientRect().right;
    this.element.style.right = `${Math.max(0, right) + gutter}px`;
  }
}
