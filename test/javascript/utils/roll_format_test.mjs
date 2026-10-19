import assert from "node:assert/strict";
import { test } from "node:test";
import { rollFrame } from "../../../app/javascript/utils/roll_format.mjs";

// The owner (2026-10-18): rolling Home's net worth from CA$662.82 to a day
// worth over a thousand showed "CA$1670.77" — the frames took the resting
// figure's lack of a thousands separator.
test("a roll into the thousands groups its digits", () => {
  assert.equal(rollFrame("CA$1,670.77", "CA$662.82", 0), "CA$1,670.77");
  assert.equal(rollFrame("CA$662.82", "CA$1,670.77", 1), "CA$1,670.77");
  assert.match(rollFrame("CA$1,670.77", "CA$662.82", 0.5), /^CA\$1,\d{3}\.\d{2}$/);
});

test("a roll keeps the target's own separators and decimals", () => {
  assert.equal(rollFrame("1.234,50 €", "2.000,00 €", 1), "2.000,00 €");
  assert.equal(rollFrame("$10", "$30", 0.5), "$20");
});

test("text it cannot read comes back as the target", () => {
  assert.equal(rollFrame("—", "$30", 0.5), "$30");
});
