import { Controller } from "@hotwired/stimulus";

// Connects to data-controller="month-grid".
//
// The month cells are ordinary links: they render without JavaScript, every
// one is in the tab order, and screen readers announce the label and status.
// This controller adds grid-style focus movement on top, so a keyboard user
// can walk the calendar with the arrow keys, Home and End.
export default class extends Controller {
  navigate(event) {
    const links = Array.from(this.element.querySelectorAll("a[href]"));
    const current = event.target.closest?.("a[href]");
    const index = links.indexOf(current);
    if (index === -1) return;

    const next = this.nextIndex(
      event.key,
      index,
      links.length,
      this.columnCount,
    );
    if (next === null) return;

    event.preventDefault();
    links[next].focus();
  }

  nextIndex(key, index, length, columns) {
    switch (key) {
      case "ArrowRight":
        return Math.min(index + 1, length - 1);
      case "ArrowLeft":
        return Math.max(index - 1, 0);
      case "ArrowDown":
        return Math.min(index + columns, length - 1);
      case "ArrowUp":
        return Math.max(index - columns, 0);
      case "Home":
        return 0;
      case "End":
        return length - 1;
      default:
        return null;
    }
  }

  // The grid is responsive (2, 3 or 6 columns), so the row stride comes from
  // what the browser actually rendered rather than a hard-coded count.
  get columnCount() {
    const columns = getComputedStyle(this.element).gridTemplateColumns;
    return columns.split(" ").filter(Boolean).length || 1;
  }
}
