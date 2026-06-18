/**
 * ResponseTimeWidget - API response time metric
 * Specialized metric for response times
 */

import { MetricWidget } from './MetricWidget';

interface ResponseTimeWidgetProps {
  avgMs: number;
  trend: 'up' | 'down' | 'stable';
  changePercent?: number;
}

export function ResponseTimeWidget({ avgMs, trend, changePercent }: Readonly<ResponseTimeWidgetProps>) {
  return (
    <MetricWidget
      label="Avg Response Time"
      value={avgMs}
      unit="ms"
      trend={trend}
      change={changePercent}
    />
  );
}
