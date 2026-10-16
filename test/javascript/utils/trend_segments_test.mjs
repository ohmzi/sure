import assert from "node:assert/strict";
import { test } from "node:test";
import { trendSegmentStops } from "../../../app/javascript/utils/trend_segments.mjs";

// Each point carries the colour of the move INTO it (its server-side trend,
// computed with the account's favorable direction): a credit card's balance
// going down is green and up is red; a cash account's up is green.
const GREEN = "#10A861";
const RED = "#EC2222";
const GRAY = "#737373";

test("each segment takes the colour of the point it moves into, with hard edges", () => {
  const stops = trendSegmentStops(
    [
      { x: 0, color: GRAY },
      { x: 50, color: RED },
      { x: 100, color: GREEN },
    ],
    { x0: 0, x1: 100 },
  );

  assert.deepEqual(stops, [
    { offset: 0, color: RED },
    { offset: 50, color: RED },
    { offset: 50, color: GREEN },
    { offset: 100, color: GREEN },
  ]);
});

test("offsets are percentages of the drawn range, not raw pixels", () => {
  const stops = trendSegmentStops(
    [
      { x: 20, color: GRAY },
      { x: 120, color: RED },
    ],
    { x0: 20, x1: 220 },
  );

  assert.deepEqual(stops, [
    { offset: 0, color: RED },
    { offset: 50, color: RED },
  ]);
});

test("a point with no colour falls back to the series colour", () => {
  const stops = trendSegmentStops(
    [
      { x: 0, color: null },
      { x: 10, color: undefined },
    ],
    { x0: 0, x1: 10 },
    GREEN,
  );

  assert.deepEqual(stops, [
    { offset: 0, color: GREEN },
    { offset: 100, color: GREEN },
  ]);
});

test("fewer than two points, or an empty range, has nothing to colour", () => {
  assert.deepEqual(trendSegmentStops([{ x: 0, color: RED }], { x0: 0, x1: 10 }), []);
  assert.deepEqual(
    trendSegmentStops(
      [
        { x: 5, color: RED },
        { x: 5, color: RED },
      ],
      { x0: 5, x1: 5 },
    ),
    [],
  );
});
