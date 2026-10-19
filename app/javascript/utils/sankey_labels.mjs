// Label-collision rule for the new preview Sankey chart.
// Nodes compete for labels only within their own
// visual column: d3-sankey's justify alignment can place same-depth nodes
// in different columns (sinks flush right), so columns are keyed by x0,
// not depth. Within a column, labels are considered in descending
// node-value order and kept only when they clear the minimum spacing from
// every label already kept. A small node can no longer hide a large
// category's label merely by sitting above it: the prominent node is
// labeled first, and the small neighbor is the one that yields.
export function hiddenSankeyLabels(nodes, { height, minSpacing }) {
  const hiddenLabels = new Set();
  const isLargeGraph = height > 600;
  const spacing = isLargeGraph ? minSpacing * 0.7 : minSpacing;

  // Group nodes by visual column (x position assigned by d3-sankey)
  const columns = new Map();
  nodes.forEach((node) => {
    const column = Math.round(node.x0);
    if (!columns.has(column)) columns.set(column, []);
    columns.get(column).push(node);
  });

  columns.forEach((columnNodes) => {
    // Most significant nodes claim their labels first; ties fall back to
    // vertical position so the rule stays deterministic.
    const byProminence = [...columnNodes].sort((a, b) => {
      if (b.value !== a.value) return b.value - a.value;
      return (a.y0 + a.y1) / 2 - (b.y0 + b.y1) / 2;
    });

    const keptYs = [];

    byProminence.forEach((node) => {
      const nodeY = (node.y0 + node.y1) / 2;
      const nodeHeight = node.y1 - node.y0;

      // Tall bars in large graphs always earn their label.
      if (
        (isLargeGraph && nodeHeight > spacing * 1.5) ||
        keptYs.every((keptY) => Math.abs(nodeY - keptY) >= spacing)
      ) {
        keptYs.push(nodeY);
      } else {
        hiddenLabels.add(node.index);
      }
    });
  });

  return hiddenLabels;
}

// Labels that would be drawn over another label, across columns (the owner,
// 2026-10-18: on a phone a middle column's labels ran into the next
// column's). Each entry is { index, value, box: { x, y, width, height } }
// from the label's drawn box. Larger flows claim their space first; a label
// overlapping one already placed, or one of the `obstacles` (other columns'
// bars), is hidden. Labels in `alreadyHidden` take no room.
export function overlappingSankeyLabels(
  labels,
  { alreadyHidden = new Set(), obstacles = [], gap = 2 } = {},
) {
  const hidden = new Set();
  const placed = [...obstacles];
  const overlaps = (a, b) =>
    a.x < b.x + b.width + gap &&
    b.x < a.x + a.width + gap &&
    a.y < b.y + b.height + gap &&
    b.y < a.y + a.height + gap;

  [...labels]
    .filter((label) => !alreadyHidden.has(label.index))
    .sort((a, b) => b.value - a.value)
    .forEach((label) => {
      if (placed.some((box) => overlaps(box, label.box))) {
        hidden.add(label.index);
      } else {
        placed.push(label.box);
      }
    });

  return hidden;
}
