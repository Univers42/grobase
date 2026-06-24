// chart-geometry.ts — pure geometry helpers for the SVG revenue chart, kept out of
// the component so each function stays small and testable.

/** ChartPoint is one bar/area datum: a label and a value. */
export type ChartPoint = { label: string; value: number };

/** ChartGeometry holds the computed paths + bar rects for a series. */
export type ChartGeometry = {
  area: string;
  line: string;
  bars: { x: number; y: number; w: number; h: number }[];
  max: number;
};

/** scaleY maps a value to a y-coordinate within the plot height (0 at top). */
function scaleY(value: number, max: number, height: number): number {
  return height - (max === 0 ? 0 : (value / max) * height);
}

/** geometry computes the area path, top line, and bar rects for the series. */
export function geometry(data: ChartPoint[], width: number, height: number): ChartGeometry {
  const max = Math.max(1, ...data.map((d) => d.value));
  const step = data.length > 1 ? width / (data.length - 1) : width;
  const coords = data.map((d, i) => ({ x: i * step, y: scaleY(d.value, max, height) }));
  const line = coords.map((p, i) => `${i ? 'L' : 'M'}${p.x.toFixed(1)} ${p.y.toFixed(1)}`).join(' ');
  const area = `${line} L${width.toFixed(1)} ${height} L0 ${height} Z`;
  const bw = Math.max(2, (width / data.length) * 0.42);
  const bars = data.map((d, i) => {
    const y = scaleY(d.value, max, height);
    return { x: i * step - bw / 2, y, w: bw, h: height - y };
  });
  return { area, line, bars, max };
}
