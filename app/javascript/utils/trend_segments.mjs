// Hard-edged gradient stops that colour a trend line segment by segment.
//
// Each point carries the colour of the move INTO it — its server-side
// trend.color, computed with the account's favorable direction — so a credit
// card's balance coming down is green and going up is red, while a cash
// account's going up is green. The segment from point i-1 to point i takes
// point i's colour; two stops at the same offset make the change a hard edge.
//
// `points` are { x, color } with x already in pixels; offsets come back as
// percentages of [x0, x1], the line's drawn range.
export function trendSegmentStops(points, { x0, x1 }, fallbackColor = null) {
  const width = x1 - x0;
  if (!Array.isArray(points) || points.length < 2 || !(width > 0)) return [];

  const offset = (x) => ((x - x0) / width) * 100;
  const stops = [];
  for (let i = 1; i < points.length; i++) {
    const color = points[i].color || fallbackColor;
    stops.push({ offset: offset(points[i - 1].x), color });
    stops.push({ offset: offset(points[i].x), color });
  }
  return stops;
}
