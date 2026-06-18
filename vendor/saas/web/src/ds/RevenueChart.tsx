// RevenueChart.tsx — a hand-rolled SVG area+line revenue chart from primitives. It
// is role="img" with an aria-label summary plus a visually-hidden data table, so
// the trend is accessible without a charting library.

import { useId } from 'react';
import { geometry } from './chart-geometry';
import type { ChartPoint } from './chart-geometry';

/** RevenueChartProps describes the series and how to format the values. */
export type RevenueChartProps = {
  data: ChartPoint[];
  height?: number;
  format?: (value: number) => string;
  ariaLabel?: string;
};

const W = 560;

/** RevenueChart renders an accessible violet area chart with a hidden summary. */
export function RevenueChart({ data, height = 200, format = (v) => `$${v}`, ariaLabel = 'Revenue over time' }: RevenueChartProps) {
  const gid = useId().replace(/:/g, '');
  const g = geometry(data, W, height);
  const last = data.at(-1)?.value ?? 0;

  return (
    <figure className="m-0">
      <svg viewBox={`0 0 ${W} ${height}`} width="100%" height={height} role="img" aria-label={`${ariaLabel}. Latest ${format(last)}.`} preserveAspectRatio="none">
        <defs>
          <linearGradient id={`fill-${gid}`} x1="0" y1="0" x2="0" y2="1">
            <stop offset="0%" stopColor="#7C5CFF" stopOpacity="0.45" />
            <stop offset="100%" stopColor="#7C5CFF" stopOpacity="0" />
          </linearGradient>
        </defs>
        {[0.25, 0.5, 0.75].map((f) => (
          <line key={f} x1="0" x2={W} y1={height * f} y2={height * f} stroke="rgba(255,255,255,0.05)" strokeWidth="1" />
        ))}
        <path d={g.area} fill={`url(#fill-${gid})`} />
        <path d={g.line} fill="none" stroke="#7C5CFF" strokeWidth="2.5" strokeLinecap="round" strokeLinejoin="round" />
        {g.bars.map((b, i) => (
          <rect key={i} x={b.x} y={b.y} width={b.w} height={b.h} rx="2" fill="#39E5C8" fillOpacity="0.14" />
        ))}
      </svg>
      <figcaption className="sr-only">
        <table>
          <caption>{ariaLabel}</caption>
          <tbody>
            {data.map((d) => (
              <tr key={d.label}>
                <th scope="row">{d.label}</th>
                <td>{format(d.value)}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </figcaption>
    </figure>
  );
}
