/**
 * DbLatencyWidget - Database latency metric
 * Specialized metric for DB query times
 */

import { MetricWidget } from './MetricWidget';

interface DbLatencyWidgetProps {
  avgMs: number;
  trend: 'up' | 'down' | 'stable';
  changePercent?: number;
}

export function DbLatencyWidget({ avgMs, trend, changePercent }: Readonly<DbLatencyWidgetProps>) {
  return (
    <MetricWidget label="DB Latency" value={avgMs} unit="ms" trend={trend} change={changePercent} />
  );
}
