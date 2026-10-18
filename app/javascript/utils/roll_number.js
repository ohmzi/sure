// Rolls the amount shown in an element to a new one (the owner, 2026-10-18:
// scrubbing a chart should move the big number "in animation", like a stock
// app). It tweens the number inside the text and keeps the target's own
// currency, separators and decimals; anything it cannot read, or a reader who
// asked for less motion, gets the new text at once.

const NUMBER = /-?\d(?:[\d.,'   ]*\d)?/;
const running = new WeakMap();

function parse(text) {
  const match = text.match(NUMBER);
  if (!match) return null;

  const raw = match[0];
  const decimalPart = raw.match(/[.,](\d{1,2})$/);
  const decimals = decimalPart ? decimalPart[1].length : 0;
  const integerPart = decimalPart ? raw.slice(0, -decimals - 1) : raw;
  const negative =
    raw.startsWith("-") || /[−-]\s*\D*$/.test(text.slice(0, match.index));

  return {
    before: text.slice(0, match.index),
    after: text.slice(match.index + raw.length),
    decimals,
    decimalSeparator: decimalPart ? raw.at(-decimals - 1) : "",
    groupSeparator: integerPart.replace(/^-/, "").match(/[^\d]/)?.[0] ?? "",
    value:
      (Number(raw.replace(/[^\d]/g, "")) / 10 ** decimals) *
      (negative ? -1 : 1),
    negative,
  };
}

function format(shape, value) {
  const [whole, fraction] = Math.abs(value).toFixed(shape.decimals).split(".");
  const grouped = whole.replace(/\B(?=(\d{3})+(?!\d))/g, shape.groupSeparator);
  return (
    shape.before +
    (fraction ? grouped + shape.decimalSeparator + fraction : grouped) +
    shape.after
  );
}

export function rollText(element, text, duration = 180) {
  const previous = running.get(element);
  if (previous) cancelAnimationFrame(previous);

  const from = parse(element.textContent);
  const to = parse(text);
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
    const eased = 1 - (1 - progress) ** 3;
    if (progress < 1) {
      element.textContent = format(
        to,
        from.value + (to.value - from.value) * eased,
      );
      running.set(element, requestAnimationFrame(step));
    } else {
      element.textContent = text;
      running.delete(element);
    }
  };
  running.set(element, requestAnimationFrame(step));
}
