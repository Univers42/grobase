/**
 * CoverageWidget - Test coverage metric
 * Specialized metric for code coverage percentage
 */

import { MetricWidget } from './MetricWidget';

interface CoverageWidgetProps {
  coveragePercent: number;
  trend: 'up' | 'down' | 'stable';
  changePercent?: number;
}

export function CoverageWidget({ coveragePercent, trend, changePercent }: Readonly<CoverageWidgetProps>) {
  return (
    <MetricWidget
      label="Test Coverage"
      value={coveragePercent}
      unit="%"
      trend={trend}
      change={changePercent}
    />
  );
}
