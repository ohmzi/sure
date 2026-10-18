import { Controller } from "@hotwired/stimulus";

// A headline amount rolls up to its value as the page opens (the animation
// pass, 2026-10-18), keeping its own currency, separators and decimals. It
// runs once, on a text-only element, and not for a reader who asked for less
// motion; the original text is always what it ends on.
export default class extends Controller {
  static values = { duration: { type: Number, default: 700 } };

  connect() {
    if (window.matchMedia("(prefers-reduced-motion: reduce)").matches) return;
    if (this.element.children.length > 0) return;

    this.text = this.element.textContent;
    const match = this.text.match(/\d(?:[\d.,'   ]*\d)?/);
    if (!match) return;

    const raw = match[0];
    const decimalPart = raw.match(/[.,](\d{1,2})$/);
    const decimals = decimalPart ? decimalPart[1].length : 0;
    const decimalSeparator = decimalPart ? raw.at(-decimals - 1) : "";
    const integerPart = decimalPart ? raw.slice(0, -decimals - 1) : raw;
    const groupSeparator = integerPart.match(/[^\d]/)?.[0] ?? "";
    const target = Number(raw.replace(/[^\d]/g, "")) / 10 ** decimals;
    if (!Number.isFinite(target) || target === 0) return;

    const before = this.text.slice(0, match.index);
    const after = this.text.slice(match.index + raw.length);
    const format = (value) => {
      const [whole, fraction] = value.toFixed(decimals).split(".");
      const grouped = whole.replace(/\B(?=(\d{3})+(?!\d))/g, groupSeparator);
      return before + (fraction ? grouped + decimalSeparator + fraction : grouped) + after;
    };

    // Turbo's page cache must keep the real figure, not a frame of the roll.
    this.finish = () => this.disconnect();
    document.addEventListener("turbo:before-cache", this.finish, { once: true });

    const started = performance.now();
    const step = (now) => {
      const progress = Math.min(1, (now - started) / this.durationValue);
      const eased = 1 - (1 - progress) ** 3;
      if (progress < 1) {
        this.element.textContent = format(target * eased);
        this.frame = requestAnimationFrame(step);
      } else {
        this.element.textContent = this.text;
      }
    };
    this.frame = requestAnimationFrame(step);
  }

  disconnect() {
    if (this.finish) document.removeEventListener("turbo:before-cache", this.finish);
    if (this.frame) cancelAnimationFrame(this.frame);
    if (this.text !== undefined) this.element.textContent = this.text;
  }
}
