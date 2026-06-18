// overview-data.ts — the overview section's domain models + pure derivations. Live
// rows arrive as untyped records, so each is narrowed through guards (no `any`),
// and the revenue series is bucketed from real posted transactions here so the
// hook and components stay thin.

import type { Row } from '../../lib/db';
import type { IconName } from '../../ds/Icon';
import type { ChartPoint } from '../../ds/chart-geometry';
import { asString, asNumber } from '../../lib/guards';

/** Kpi is one headline metric tile for the overview grid. */
export type Kpi = { label: string; value: string; delta: number; icon: IconName; series: number[] };

/** ActivityItem is the narrowed Mongo `activity` record the feed renders. */
export type ActivityItem = { id: string; actor: string; action: string; target: string; at: string };

/** toActivityItem narrows an untyped Mongo activity row into a typed ActivityItem.
 *  The data plane surfaces Mongo's `_id` as `id` (hex string); read `id` first. */
export function toActivityItem(row: Row): ActivityItem {
  return {
    id: asString(row.id ?? row._id),
    actor: asString(row.actor, 'someone'),
    action: asString(row.action, 'did'),
    target: asString(row.target),
    at: asString(row.ts),
  };
}

/** dayKey returns a stable YYYY-MM-DD key for an ISO timestamp (UTC). */
function dayKey(iso: string): string {
  const ms = Date.parse(iso);
  return Number.isNaN(ms) ? '' : new Date(ms).toISOString().slice(0, 10);
}

/** dayLabel renders a YYYY-MM-DD key as a compact "Jun 18" axis label. */
function dayLabel(key: string): string {
  const d = new Date(`${key}T00:00:00Z`);
  return Number.isNaN(d.getTime())
    ? key
    : d.toLocaleDateString('en-US', { month: 'short', day: 'numeric', timeZone: 'UTC' });
}

/** revenueSeries buckets posted-transaction cents into the last `days` daily
 * points (oldest→newest), so the chart reflects real movement, not samples. */
export function revenueSeries(rows: readonly Row[], days = 8): ChartPoint[] {
  const totals = new Map<string, number>();
  for (const row of rows) {
    const key = dayKey(asString(row.created_at));
    if (key) totals.set(key, (totals.get(key) ?? 0) + asNumber(row.amount_cents));
  }
  const points: ChartPoint[] = [];
  const today = new Date();
  for (let i = days - 1; i >= 0; i--) {
    const d = new Date(today);
    d.setUTCDate(d.getUTCDate() - i);
    const key = d.toISOString().slice(0, 10);
    points.push({ label: dayLabel(key), value: (totals.get(key) ?? 0) / 100 });
  }
  return points;
}

/** sumCents totals a single integer-cent column across untyped rows. */
export function sumCents(rows: readonly Row[], column: string): number {
  let total = 0;
  for (const row of rows) total += asNumber(row[column]);
  return total;
}

/** seriesTail extracts the last `n` values of a ChartPoint series for a sparkline. */
export function seriesTail(points: readonly ChartPoint[], n: number): number[] {
  return points.slice(-n).map((p) => Math.round(p.value));
}

/** relativeTime renders an ISO timestamp as a compact "now"/"5m"/"2h"/"3d" label. */
export function relativeTime(iso: string): string {
  const then = Date.parse(iso);
  if (Number.isNaN(then)) return '';
  const secs = Math.max(0, Math.round((Date.now() - then) / 1000));
  if (secs < 60) return 'now';
  const mins = Math.round(secs / 60);
  if (mins < 60) return `${mins}m`;
  const hours = Math.round(mins / 60);
  if (hours < 24) return `${hours}h`;
  const days = Math.round(hours / 24);
  return days < 7 ? `${days}d` : new Date(then).toLocaleDateString();
}
