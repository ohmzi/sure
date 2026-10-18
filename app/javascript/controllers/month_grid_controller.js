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
  // what the browser actually rendered rather than a hard-coded count. The
  // computed value is whitespace-separated, but a track function can carry
  // spaces of its own ("minmax(0px, 1fr)"), so count only top-level tracks.
  // `none` (a grid with no explicit columns) falls back to one.
  get columnCount() {
    const columns = getComputedStyle(this.element).gridTemplateColumns.trim();
    if (!columns || columns === "none") return 1;

    let depth = 0;
    let count = 0;
    let inTrack = false;
    for (const character of columns) {
      if (character === "(") depth += 1;
      if (character === ")") depth = Math.max(depth - 1, 0);

      if (/\s/.test(character) && depth === 0) {
        inTrack = false;
      } else if (!inTrack) {
        count += 1;
        inTrack = true;
      }
    }

    return count || 1;
  }
}
