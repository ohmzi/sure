// Rolls the amount shown in an element to a new one (the owner, 2026-10-18:
// scrubbing a chart should move the big number "in animation", like a stock
// app). It tweens the number inside the text and keeps the target's own
// currency, separators and decimals (roll_format); anything it cannot read,
// or a reader who asked for less motion, gets the new text at once.
import { parseAmount, rollFrame } from "utils/roll_format";

const running = new WeakMap();

export function rollText(element, text, duration = 180) {
  const previous = running.get(element);
  if (previous) cancelAnimationFrame(previous);

  const fromText = element.textContent;
  const from = parseAmount(fromText);
  const to = parseAmount(text);
  const reduce = window.matchMedia("(prefers-reduced-motion: reduce)").matches;

  // A sign change rewrites the text around the number, so it cannot roll.
  if (
    reduce ||
    !from ||
    !to ||
    from.negative !== to.negative ||
    from.value === to.value
  ) {
    element.textContent = text;
    return;
  }

  const started = performance.now();
  const step = (now) => {
    const progress = Math.min(1, (now - started) / duration);
    if (progress < 1) {
      element.textContent = rollFrame(fromText, text, 1 - (1 - progress) ** 3);
      running.set(element, requestAnimationFrame(step));
    } else {
      element.textContent = text;
      running.delete(element);
    }
  };
  running.set(element, requestAnimationFrame(step));
}
