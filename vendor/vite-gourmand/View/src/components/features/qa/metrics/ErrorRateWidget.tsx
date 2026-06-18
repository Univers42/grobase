/**
 * ErrorRateWidget - API error rate metric
 * Specialized metric for error percentages
 */

import { MetricWidget } from './MetricWidget';

interface ErrorRateWidgetProps {
  errorPercent: number;
  trend: 'up' | 'down' | 'stable';
  changePercent?: number;
}

export function ErrorRateWidget({ errorPercent, trend, changePercent }: Readonly<ErrorRateWidgetProps>) {
  return (
    <MetricWidget
      label="Error Rate"
      value={errorPercent}
      unit="%"
      trend={trend}
      change={changePercent}
    />
  );
}
