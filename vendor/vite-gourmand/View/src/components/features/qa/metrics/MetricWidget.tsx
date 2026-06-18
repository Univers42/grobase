/**
 * MetricWidget - Base metric display widget
 * Shows value, label, and trend with glassmorphism
 */

import './MetricWidget.css';

interface MetricWidgetProps {
  label: string;
  value: number | string;
  unit?: string;
  trend?: 'up' | 'down' | 'stable';
  change?: number;
}

const trendIcons = {
  up: '↑',
  down: '↓',
  stable: '→',
};

export function MetricWidget({ label, value, unit, trend = 'stable', change }: Readonly<MetricWidgetProps>) {
  const trendClass = `metric-widget-trend--${trend}`;
  const hasChange = typeof change === 'number';
  const showTrend = hasChange || trend !== 'stable';

  return (
    <article className="metric-widget">
      <span className="metric-widget-label">{label}</span>
      <div className="metric-widget-value-row">
        <span className="metric-widget-value">{value}</span>
        {unit && <span className="metric-widget-unit">{unit}</span>}
      </div>
      {showTrend && (
        <span className={`metric-widget-trend ${trendClass}`}>
          {trendIcons[trend]} {hasChange ? `${Math.abs(change)}%` : ''}
        </span>
      )}
    </article>
  );
}
