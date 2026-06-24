// Sparkline.tsx — a tiny hand-rolled SVG line chart from a number series. No chart
// library; the polyline points are computed from the data extent.

/** SparklineProps describes the series and the rendered box. */
export type SparklineProps = {
  data: number[];
  width?: number;
  height?: number;
  stroke?: string;
  label?: string;
};

/** points maps the series to "x,y x,y …" polyline coordinates within the box. */
function points(data: number[], width: number, height: number): string {
  if (data.length < 2) return '';
  const min = Math.min(...data);
  const max = Math.max(...data);
  const span = max - min || 1;
  const step = width / (data.length - 1);
  return data
    .map((v, i) => `${(i * step).toFixed(1)},${(height - ((v - min) / span) * height).toFixed(1)}`)
    .join(' ');
}

/** Sparkline renders a minimal trend line; falls back to a flat baseline. */
export function Sparkline({ data, width = 96, height = 28, stroke = '#7C5CFF', label = 'trend' }: SparklineProps) {
  const pad = 2;
  const pts = points(data, width - pad * 2, height - pad * 2);
  return (
    <svg width={width} height={height} viewBox={`0 0 ${width} ${height}`} role="img" aria-label={label} className="overflow-visible">
      <g transform={`translate(${pad},${pad})`}>
        <polyline points={pts} fill="none" stroke={stroke} strokeWidth={1.8} strokeLinecap="round" strokeLinejoin="round" />
      </g>
    </svg>
  );
}
