import { Controller } from "@hotwired/stimulus";
import { rollText } from "utils/roll_number";

// Switching Home's net worth range (1W / 1M / 1Y) reloads only its card
// (the owner, 2026-10-18): the new figure rolls from the one it replaces
// instead of snapping, and the line draws itself in again.
export default class extends Controller {
  remember() {
    this.previous = this.#value()?.textContent.trim();
  }

  roll() {
    const value = this.#value();
    if (!value || !this.previous) return;

    const next = value.textContent.trim();
    value.textContent = this.previous;
    rollText(value, next, 500);
    this.previous = null;
  }

  #value() {
    return this.element.querySelector("[data-hero-scrub-target='value']");
  }
}
