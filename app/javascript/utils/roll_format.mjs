// The text a rolling figure shows part-way between two amounts (roll_number),
// in the target's own currency, separators and decimals. The thousands
// separator comes from whichever end has one, so a roll from CA$662.82 into
// the thousands reads CA$1,670.77, not CA$1670.77 (the owner, 2026-10-18).

const NUMBER = /-?\d(?:[\d.,'   ]*\d)?/;

export function parseAmount(text) {
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

function format(shape, value, groupSeparator) {
  const [whole, fraction] = Math.abs(value).toFixed(shape.decimals).split(".");
  const grouped = whole.replace(/\B(?=(\d{3})+(?!\d))/g, groupSeparator);
  return (
    shape.before +
    (fraction ? grouped + shape.decimalSeparator + fraction : grouped) +
    shape.after
  );
}

// `progress` is the eased share of the way from `fromText` to `toText`.
export function rollFrame(fromText, toText, progress) {
  const from = parseAmount(fromText);
  const to = parseAmount(toText);
  if (!from || !to || progress >= 1) return toText;
  if (progress <= 0) return fromText;

  // A thousands separator only when the target's decimal mark differs, so
  // "1.234,50" never borrows a "." group mark from a figure using "." for
  // decimals.
  let groupSeparator = to.groupSeparator;
  if (!groupSeparator && from.groupSeparator !== to.decimalSeparator)
    groupSeparator = from.groupSeparator || "";
  if (!groupSeparator && to.decimalSeparator !== ",") groupSeparator = ",";
  if (!groupSeparator && to.decimalSeparator === ",") groupSeparator = ".";

  return format(
    to,
    from.value + (to.value - from.value) * progress,
    groupSeparator,
  );
}
